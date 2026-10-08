/**
 * @description Batch + Scheduled job that deactivates Users according to
 * per-profile rules defined in Auto_User_Inactive__mdt. Each rule is either:
 * a fixed Deactivation_Date__c on the User that has passed, or an inactivity
 * window based on LastLoginDate (Number_of_Days__c).
 * Implements Database.Stateful so results are accumulated across all chunks
 * and reported once in finish().
 *
 * @author Houssam Saoudy
 * @group User Management
 * @see Auto_User_Inactive__mdt
 */
@SuppressWarnings(
	'PMD.StdCyclomaticComplexity,PMD.CognitiveComplexity,PMD.CyclomaticComplexity'
)
public with sharing class DeactivateUsersBatch implements Database.Batchable<sObject>, Database.Stateful, Schedulable {
	/**
	 * @description Active rules keyed by profile name. Loaded once per job
	 * run (in start()), not once per chunk.
	 */
	private Map<String, Auto_User_Inactive__mdt> profileRulesByName;

	/**
	 * @description Stateful count of users evaluated across all chunks, for the finish() summary.
	 */
	private Integer totalEvaluated = 0;

	/**
	 * @description Stateful count of users successfully deactivated across all chunks.
	 */
	private Integer totalDeactivated = 0;

	/**
	 * @description Stateful list of failure messages accumulated across all chunks.
	 */
	private List<String> failures = new List<String>();

	/**
	 * @description Id of the user this job runs as. That account is never deactivated.
	 */
	private static final Id RUNNING_USER_ID = UserInfo.getUserId();

	// ---- Test seams -------------------------------------------------------
	// Custom metadata can't be inserted via DML, and the "running user" is
	// fixed by the org context, so both are made overridable for tests only.
	// Neither is ever touched in production code paths.

	/**
	 * @description Test-only override for the rules returned by loadRules().
	 */
	@TestVisible
	private static Map<String, Auto_User_Inactive__mdt> mockRules;

	/**
	 * @description Test-only override for the running user Id.
	 */
	@TestVisible
	private static Id mockRunningUserId;
	// -------------------------------------------------------------------

	/**
	 * @description Loads the deactivation rules and builds the query locator
	 * for active users whose profile has a rule configured.
	 * @param bc The batchable context
	 * @return A QueryLocator over the candidate User records
	 */
	public Database.QueryLocator start(Database.BatchableContext bc) {
		profileRulesByName = loadRules();

		// Filter in SOQL to only the profiles that have a rule configured,
		// instead of scanning every active user in the org.
		Set<String> profileNames = profileRulesByName.keySet();

		String query =
			'SELECT Id, Deactivation_Date__c, IsActive, Profile.Name, LastLoginDate ' +
			'FROM User ' +
			'WHERE IsActive = true AND Profile.Name IN :profileNames';

		return Database.getQueryLocator(query);
	}

	/**
	 * @description Evaluates each User in the chunk against its profile rule
	 * and deactivates those that qualify. Skips the running user, and skips
	 * the whole chunk if the running user cannot update User.IsActive.
	 * @param bc The batchable context
	 * @param scope The chunk of User records to evaluate
	 */
	public void execute(Database.BatchableContext bc, List<sObject> scope) {
		if (!Schema.sObjectType.User.fields.IsActive.isUpdateable()) {
			failures.add(
				'Running user lacks FLS access to update User.IsActive; chunk skipped.'
			);
			return;
		}

		Id runningUserId = (System.Test.isRunningTest() &&
			mockRunningUserId != null)
			? mockRunningUserId
			: RUNNING_USER_ID;

		List<User> usersToDeactivate = new List<User>();

		for (sObject s : scope) {
			User userRecord = (User) s;
			totalEvaluated++;

			if (userRecord.Id == runningUserId) {
				continue; // safety: don't deactivate the running/integration user
			}

			Auto_User_Inactive__mdt rule = profileRulesByName.get(
				userRecord.Profile.Name
			);
			if (rule == null) {
				continue;
			}

			if (
				shouldDeactivate(
					userRecord.Deactivation_Date__c,
					userRecord.LastLoginDate,
					rule
				)
			) {
				userRecord.IsActive = false;
				usersToDeactivate.add(userRecord);
			}
		}

		if (usersToDeactivate.isEmpty()) {
			return;
		}

		List<Database.SaveResult> results = Database.update(
			usersToDeactivate,
			false
		);
		for (Integer i = 0; i < results.size(); i++) {
			if (results[i].isSuccess()) {
				totalDeactivated++;
			} else {
				failures.add(
					usersToDeactivate[i].Id +
						': ' +
						results[i].getErrors()[0].getMessage()
				);
			}
		}
	}

	/**
	 * @description Sends the accumulated summary email once all chunks have run.
	 * @param bc The batchable context
	 */
	public void finish(Database.BatchableContext bc) {
		sendSummaryEmail();
	}

	/**
	 * @description Schedulable entry point; launches the batch with a scope size of 200.
	 * @param ctx The schedulable context
	 */
	public void execute(SchedulableContext ctx) {
		Database.executeBatch(new DeactivateUsersBatch(), 200);
	}

	// ---------------------------------------------------------------------
	// Helpers
	// ---------------------------------------------------------------------

	/**
	 * @description Gets all Auto_User_Inactive__mdt records, keyed by Label
	 * (the profile name). Returns mockRules instead when running in a test
	 * and it has been set.
	 * @return Map of profile name to deactivation rule
	 */
	private Map<String, Auto_User_Inactive__mdt> loadRules() {
		if (System.Test.isRunningTest() && mockRules != null) {
			return mockRules;
		}

		Map<String, Auto_User_Inactive__mdt> rules = new Map<String, Auto_User_Inactive__mdt>();
		// getAll() is keyed by DeveloperName, so re-key by Label (the profile name).
		for (
			Auto_User_Inactive__mdt rule : Auto_User_Inactive__mdt.getAll().values()
		) {
			rules.put(rule.Label, rule);
		}
		return rules;
	}

	/**
	 * @description Decides whether a user should be deactivated under a rule.
	 * Takes the two relevant values as primitives, rather than a User sObject,
	 * so tests can exercise every branch, including LastLoginDate scenarios,
	 * without hitting that field's read-only restriction.
	 * @param deactivationDate The user's Deactivation_Date__c; used when the rule is not login-based
	 * @param lastLoginDate The user's LastLoginDate; a null value counts as inactive for login-based rules
	 * @param rule The rule for the user's profile
	 * @return True if the user should be deactivated
	 */
	@TestVisible
	private Boolean shouldDeactivate(
		Date deactivationDate,
		Datetime lastLoginDate,
		Auto_User_Inactive__mdt rule
	) {
		if (!rule.From_Last_Login_Date__c) {
			return deactivationDate != null && deactivationDate < Date.today();
		}

		// Normalize sign so the rule works regardless of how the admin entered it.
		Integer inactivityDays = rule.Number_of_Days__c != null
			? Math.abs(rule.Number_of_Days__c.intValue())
			: 0;
		Datetime cutoff = Datetime.now().addDays(-inactivityDays);

		return lastLoginDate == null || lastLoginDate < cutoff;
	}

	/**
	 * @description Emails the evaluated, deactivated and failure counts (plus
	 * failure details) to the address in the User_Deactivation_Notification_List
	 * label, which may hold several comma-separated addresses. Does nothing
	 * if the label contains no addresses.
	 */
	private void sendSummaryEmail() {
		// TODO: replace with a real notification list (custom setting/label/queue).
		List<String> recipients = new List<String>();
		for (
			String address : System.Label.User_Deactivation_Notification_List.split(
				','
			)
		) {
			if (String.isNotBlank(address)) {
				recipients.add(address.trim());
			}
		}
		if (recipients.isEmpty()) {
			return;
		}

		Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
		mail.setToAddresses(recipients);
		mail.setSubject('User Deactivation Batch — Summary');

		String body =
			'Evaluated: ' +
			totalEvaluated +
			'\n' +
			'Deactivated: ' +
			totalDeactivated +
			'\n' +
			'Failures: ' +
			failures.size();
		if (!failures.isEmpty()) {
			body += '\n\n' + String.join(failures, '\n');
		}
		mail.setPlainTextBody(body);

		Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
	}
}