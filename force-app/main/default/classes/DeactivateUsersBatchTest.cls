/**
 * Tests for DeactivateUsersBatch.
 *
 * Two Salesforce constraints shape this test class:
 *   1. Auto_User_Inactive__mdt (custom metadata) can't be inserted via DML,
 *      so tests inject rules through the @TestVisible `mockRules` seam
 *      instead of depending on whatever happens to be deployed in the org.
 *   2. User.LastLoginDate rejects being set at all — even as a plain field
 *      assignment on an in-memory object, not just via DML. Because of
 *      that, shouldDeactivate() takes the deactivation date and last-login
 *      value as plain Date/Datetime parameters rather than a User sObject,
 *      so tests can supply any value directly without touching the
 *      restricted field.
 */
@isTest
private class DeactivateUsersBatchTest {
	private static final String TEST_PROFILE = 'Standard User';

	private static Profile getTestProfile() {
		return [SELECT Id, Name FROM Profile WHERE Name = :TEST_PROFILE LIMIT 1];
	}

	private static User buildTestUser(Id profileId, String uniqueKey) {
		return new User(
			FirstName = 'Test',
			LastName = 'User' + uniqueKey,
			Email = 'tuser' + uniqueKey + '@example.invalid',
			Username = 'tuser' + uniqueKey + '@example.invalid.test',
			Alias = 'tu' + uniqueKey.right(4),
			TimeZoneSidKey = 'America/Los_Angeles',
			LocaleSidKey = 'en_US',
			EmailEncodingKey = 'UTF-8',
			LanguageLocaleKey = 'en_US',
			ProfileId = profileId,
			IsActive = true
		);
	}

	// -----------------------------------------------------------------
	// Unit tests for the core decision logic (shouldDeactivate)
	// -----------------------------------------------------------------

	@isTest
	static void shouldDeactivate_fixedDateRule_pastDate_returnsTrue() {
		Auto_User_Inactive__mdt rule = new Auto_User_Inactive__mdt(
			Label = TEST_PROFILE,
			From_Last_Login_Date__c = false
		);

		Boolean result = new DeactivateUsersBatch()
			.shouldDeactivate(Date.today().addDays(-1), null, rule);

		System.assertEquals(
			true,
			result,
			'A past Deactivation_Date__c should be flagged'
		);
	}

	@isTest
	static void shouldDeactivate_fixedDateRule_futureOrNullDate_returnsFalse() {
		Auto_User_Inactive__mdt rule = new Auto_User_Inactive__mdt(
			Label = TEST_PROFILE,
			From_Last_Login_Date__c = false
		);

		System.assertEquals(
			false,
			new DeactivateUsersBatch()
				.shouldDeactivate(Date.today().addDays(5), null, rule),
			'Future Deactivation_Date__c should not be flagged yet'
		);
		System.assertEquals(
			false,
			new DeactivateUsersBatch().shouldDeactivate(null, null, rule),
			'Null Deactivation_Date__c should never be flagged under a fixed-date rule'
		);
	}

	@isTest
	static void shouldDeactivate_loginRule_neverLoggedIn_returnsTrue() {
		Auto_User_Inactive__mdt rule = new Auto_User_Inactive__mdt(
			Label = TEST_PROFILE,
			From_Last_Login_Date__c = true,
			Number_of_Days__c = 90
		);

		Boolean result = new DeactivateUsersBatch()
			.shouldDeactivate(null, null, rule);

		System.assertEquals(
			true,
			result,
			'A user who has never logged in should be flagged'
		);
	}

	@isTest
	static void shouldDeactivate_loginRule_staleLogin_returnsTrue() {
		Auto_User_Inactive__mdt rule = new Auto_User_Inactive__mdt(
			Label = TEST_PROFILE,
			From_Last_Login_Date__c = true,
			Number_of_Days__c = 90
		);

		Boolean result = new DeactivateUsersBatch()
			.shouldDeactivate(null, Datetime.now().addDays(-100), rule);

		System.assertEquals(
			true,
			result,
			'A login older than the configured window should be flagged'
		);
	}

	@isTest
	static void shouldDeactivate_loginRule_recentLogin_returnsFalse() {
		Auto_User_Inactive__mdt rule = new Auto_User_Inactive__mdt(
			Label = TEST_PROFILE,
			From_Last_Login_Date__c = true,
			Number_of_Days__c = 90
		);

		Boolean result = new DeactivateUsersBatch()
			.shouldDeactivate(null, Datetime.now().addDays(-5), rule);

		System.assertEquals(false, result, 'A recent login should not be flagged');
	}

	@isTest
	static void shouldDeactivate_loginRule_negativeConfiguredDays_isNormalized() {
		// Admin entered -90 instead of 90; logic should treat it the same.
		Auto_User_Inactive__mdt rule = new Auto_User_Inactive__mdt(
			Label = TEST_PROFILE,
			From_Last_Login_Date__c = true,
			Number_of_Days__c = -90
		);

		System.assertEquals(
			true,
			new DeactivateUsersBatch()
				.shouldDeactivate(null, Datetime.now().addDays(-100), rule),
			'Negative Number_of_Days__c should be normalized and still flag stale logins'
		);
		System.assertEquals(
			false,
			new DeactivateUsersBatch()
				.shouldDeactivate(null, Datetime.now().addDays(-5), rule),
			'Negative Number_of_Days__c should be normalized and not flag recent logins'
		);
	}

	// -----------------------------------------------------------------
	// End-to-end batch execution tests
	// -----------------------------------------------------------------

	@isTest
	static void execute_deactivatesQualifyingUser_viaFixedDateRule() {
		Profile p = getTestProfile();
		User dueUser = buildTestUser(p.Id, '1');
		dueUser.Deactivation_Date__c = Date.today().addDays(-1);
		User notDueUser = buildTestUser(p.Id, '2');
		notDueUser.Deactivation_Date__c = Date.today().addDays(5);
		insert new List<User>{ dueUser, notDueUser };

		DeactivateUsersBatch.mockRules = new Map<String, Auto_User_Inactive__mdt>{
			TEST_PROFILE => new Auto_User_Inactive__mdt(
				Label = TEST_PROFILE,
				From_Last_Login_Date__c = false
			)
		};
		// Point the "running user" safety check somewhere irrelevant so it
		// doesn't accidentally shield our test users.
		DeactivateUsersBatch.mockRunningUserId = UserInfo.getUserId();

		System.Test.startTest();
		Database.executeBatch(new DeactivateUsersBatch(), 200);
		System.Test.stopTest();

		Map<Id, User> resultsById = new Map<Id, User>(
			[
				SELECT Id, IsActive
				FROM User
				WHERE Id IN :new List<User>{ dueUser, notDueUser }
			]
		);
		System.assertEquals(
			false,
			resultsById.get(dueUser.Id).IsActive,
			'Past-due user should be deactivated'
		);
		System.assertEquals(
			true,
			resultsById.get(notDueUser.Id).IsActive,
			'Not-yet-due user should remain active'
		);
	}

	@isTest
	static void execute_skipsUsersWhoseProfileHasNoRule() {
		Profile p = getTestProfile();
		User unmanagedUser = buildTestUser(p.Id, '3');
		unmanagedUser.Deactivation_Date__c = Date.today().addDays(-1);
		insert unmanagedUser;

		// No rule configured for TEST_PROFILE at all.
		DeactivateUsersBatch.mockRules = new Map<String, Auto_User_Inactive__mdt>();

		System.Test.startTest();
		Database.executeBatch(new DeactivateUsersBatch(), 200);
		System.Test.stopTest();

		User result = [SELECT IsActive FROM User WHERE Id = :unmanagedUser.Id];
		System.assertEquals(
			true,
			result.IsActive,
			'Users with no matching rule should never be touched'
		);
	}

	@isTest
	static void execute_neverDeactivatesTheRunningUser() {
		Profile p = getTestProfile();
		User qualifyingUser = buildTestUser(p.Id, '4');
		qualifyingUser.Deactivation_Date__c = Date.today().addDays(-1);
		insert qualifyingUser;

		DeactivateUsersBatch.mockRules = new Map<String, Auto_User_Inactive__mdt>{
			TEST_PROFILE => new Auto_User_Inactive__mdt(
				Label = TEST_PROFILE,
				From_Last_Login_Date__c = false
			)
		};
		// Pretend this qualifying user IS the one running the job.
		DeactivateUsersBatch.mockRunningUserId = qualifyingUser.Id;

		System.Test.startTest();
		Database.executeBatch(new DeactivateUsersBatch(), 200);
		System.Test.stopTest();

		User result = [SELECT IsActive FROM User WHERE Id = :qualifyingUser.Id];
		System.assertEquals(
			true,
			result.IsActive,
			'The user flagged as the running user must never be deactivated, even if otherwise qualifying'
		);
	}

	@isTest
	static void scheduledExecution_kicksOffBatch() {
		System.Test.startTest();
		String jobId = System.schedule(
			'Test Deactivate Users Job',
			'0 0 0 1 1 ? 2099',
			new DeactivateUsersBatch()
		);
		System.Test.stopTest();

		System.assertNotEquals(
			null,
			jobId,
			'Scheduling the job should return a valid job Id'
		);
	}
}