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
@SuppressWarnings('PMD.MethodNamingConventions,PMD.ApexUnitTestClassShouldHaveRunAs')
@IsTest
private class DeactivateUsersBatchTest {
	private static final String TEST_PROFILE = 'Minimum Access - Salesforce';

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

	@IsTest
	static void shouldDeactivate_fixedDateRule_pastDate_returnsTrue() {
		Auto_User_Inactive__mdt rule = new Auto_User_Inactive__mdt(Label = TEST_PROFILE, From_Last_Login_Date__c = false);

		Boolean result = new DeactivateUsersBatch().shouldDeactivate(Date.today().addDays(-1), null, rule);

		Assert.isTrue(result, 'A past Deactivation_Date__c should be flagged');
	}

	@IsTest
	static void shouldDeactivate_fixedDateRule_futureOrNullDate_returnsFalse() {
		Auto_User_Inactive__mdt rule = new Auto_User_Inactive__mdt(Label = TEST_PROFILE, From_Last_Login_Date__c = false);

		Assert.isFalse(
			new DeactivateUsersBatch().shouldDeactivate(Date.today().addDays(5), null, rule),
			'Future Deactivation_Date__c should not be flagged yet'
		);
		Assert.isFalse(
			new DeactivateUsersBatch().shouldDeactivate(null, null, rule),
			'Null Deactivation_Date__c should never be flagged under a fixed-date rule'
		);
	}

	@IsTest
	static void shouldDeactivate_loginRule_neverLoggedIn_returnsTrue() {
		Auto_User_Inactive__mdt rule = new Auto_User_Inactive__mdt(
			Label = TEST_PROFILE,
			From_Last_Login_Date__c = true,
			Number_of_Days__c = 90
		);

		Boolean result = new DeactivateUsersBatch().shouldDeactivate(null, null, rule);

		Assert.isTrue(result, 'A user who has never logged in should be flagged');
	}

	@IsTest
	static void shouldDeactivate_loginRule_staleLogin_returnsTrue() {
		Auto_User_Inactive__mdt rule = new Auto_User_Inactive__mdt(
			Label = TEST_PROFILE,
			From_Last_Login_Date__c = true,
			Number_of_Days__c = 90
		);

		Boolean result = new DeactivateUsersBatch().shouldDeactivate(null, Datetime.now().addDays(-100), rule);

		Assert.isTrue(result, 'A login older than the configured window should be flagged');
	}

	@IsTest
	static void shouldDeactivate_loginRule_recentLogin_returnsFalse() {
		Auto_User_Inactive__mdt rule = new Auto_User_Inactive__mdt(
			Label = TEST_PROFILE,
			From_Last_Login_Date__c = true,
			Number_of_Days__c = 90
		);

		Boolean result = new DeactivateUsersBatch().shouldDeactivate(null, Datetime.now().addDays(-5), rule);

		Assert.isFalse(result, 'A recent login should not be flagged');
	}

	@IsTest
	static void shouldDeactivate_loginRule_negativeConfiguredDays_isNormalized() {
		// Admin entered -90 instead of 90; logic should treat it the same.
		Auto_User_Inactive__mdt rule = new Auto_User_Inactive__mdt(
			Label = TEST_PROFILE,
			From_Last_Login_Date__c = true,
			Number_of_Days__c = -90
		);

		Assert.isTrue(
			new DeactivateUsersBatch().shouldDeactivate(null, Datetime.now().addDays(-100), rule),
			'Negative Number_of_Days__c should be normalized and still flag stale logins'
		);
		Assert.isFalse(
			new DeactivateUsersBatch().shouldDeactivate(null, Datetime.now().addDays(-5), rule),
			'Negative Number_of_Days__c should be normalized and not flag recent logins'
		);
	}

	// -----------------------------------------------------------------
	// End-to-end batch execution tests
	// -----------------------------------------------------------------

	@IsTest
	static void execute_deactivatesQualifyingUser_viaFixedDateRule() {
		Profile p = getTestProfile();
		User dueUser = buildTestUser(p.Id, '1');
		dueUser.Deactivation_Date__c = Date.today().addDays(-1);
		User notDueUser = buildTestUser(p.Id, '2');
		notDueUser.Deactivation_Date__c = Date.today().addDays(5);
		insert new List<User>{ dueUser, notDueUser };

		DeactivateUsersBatch.mockRules = new Map<String, Auto_User_Inactive__mdt>{
			TEST_PROFILE => new Auto_User_Inactive__mdt(Label = TEST_PROFILE, From_Last_Login_Date__c = false)
		};
		// Point the "running user" safety check somewhere irrelevant so it
		// doesn't accidentally shield our test users.
		DeactivateUsersBatch.mockRunningUserId = UserInfo.getUserId();

		Test.startTest();
		Database.executeBatch(new DeactivateUsersBatch(), 200);
		Test.stopTest();

		Map<Id, User> resultsById = new Map<Id, User>(
			[
				SELECT Id, IsActive
				FROM User
				WHERE Id IN :new List<User>{ dueUser, notDueUser }
			]
		);
		Assert.isFalse(resultsById.get(dueUser.Id).IsActive, 'Past-due user should be deactivated');
		Assert.isTrue(resultsById.get(notDueUser.Id).IsActive, 'Not-yet-due user should remain active');
	}

	@IsTest
	static void execute_skipsUsersWhoseProfileHasNoRule() {
		Profile p = getTestProfile();
		User unmanagedUser = buildTestUser(p.Id, '3');
		unmanagedUser.Deactivation_Date__c = Date.today().addDays(-1);
		insert unmanagedUser;

		// No rule configured for TEST_PROFILE at all.
		DeactivateUsersBatch.mockRules = new Map<String, Auto_User_Inactive__mdt>();

		Test.startTest();
		Database.executeBatch(new DeactivateUsersBatch(), 200);
		Test.stopTest();

		User result = [SELECT IsActive FROM User WHERE Id = :unmanagedUser.Id];
		Assert.isTrue(result.IsActive, 'Users with no matching rule should never be touched');
	}

	@IsTest
	static void execute_neverDeactivatesTheRunningUser() {
		Profile p = getTestProfile();
		User qualifyingUser = buildTestUser(p.Id, '4');
		qualifyingUser.Deactivation_Date__c = Date.today().addDays(-1);
		insert qualifyingUser;

		DeactivateUsersBatch.mockRules = new Map<String, Auto_User_Inactive__mdt>{
			TEST_PROFILE => new Auto_User_Inactive__mdt(Label = TEST_PROFILE, From_Last_Login_Date__c = false)
		};
		// Pretend this qualifying user IS the one running the job.
		DeactivateUsersBatch.mockRunningUserId = qualifyingUser.Id;

		Test.startTest();
		Database.executeBatch(new DeactivateUsersBatch(), 200);
		Test.stopTest();

		User result = [SELECT IsActive FROM User WHERE Id = :qualifyingUser.Id];
		Assert.isTrue(
			result.IsActive,
			'The user flagged as the running user must never be deactivated, even if otherwise qualifying'
		);
	}

	@IsTest
	static void scheduledExecution_kicksOffBatch() {
		Test.startTest();
		String jobId = System.schedule('Test Deactivate Users Job', '0 0 0 1 1 ? 2099', new DeactivateUsersBatch());
		Test.stopTest();

		Assert.areNotEqual(null, jobId, 'Scheduling the job should return a valid job Id');
	}

	// -----------------------------------------------------------------
	// Additional coverage: helpers, failure handling, permissions
	// -----------------------------------------------------------------

	private static Database.SaveResult buildSaveResult(Boolean success, String message) {
		String json = success
			? '{"success":true,"errors":[]}'
			: '{"success":false,"errors":[{"message":"' +
			  message +
			  '","statusCode":"FIELD_CUSTOM_VALIDATION_EXCEPTION","fields":[]}]}';
		return (Database.SaveResult) System.JSON.deserialize(json, Database.SaveResult.class);
	}

	@IsTest
	static void parseRecipients_handlesSingleMultipleAndBlankValues() {
		Assert.areEqual(
			new List<String>{ 'a@example.com' },
			DeactivateUsersBatch.parseRecipients('a@example.com'),
			'A single address should be returned as-is'
		);
		Assert.areEqual(
			new List<String>{ 'a@example.com', 'b@example.com', 'c@example.com' },
			DeactivateUsersBatch.parseRecipients(' a@example.com, b@example.com ,,c@example.com '),
			'Addresses should be trimmed and blank entries dropped'
		);
		Assert.areEqual(0, DeactivateUsersBatch.parseRecipients(null).size(), 'Null should yield no recipients');
		Assert.areEqual(0, DeactivateUsersBatch.parseRecipients('  ').size(), 'Blank should yield no recipients');
		Assert.areEqual(
			0,
			DeactivateUsersBatch.parseRecipients(' , ,').size(),
			'Only separators should yield no recipients'
		);
	}

	@IsTest
	static void recordSaveResults_countsSuccessesAndCapturesFailures() {
		DeactivateUsersBatch batch = new DeactivateUsersBatch();
		List<User> users = new List<User>{ new User(Id = UserInfo.getUserId()), new User(Id = UserInfo.getUserId()) };

		batch.recordSaveResults(
			users,
			new List<Database.SaveResult>{ buildSaveResult(true, null), buildSaveResult(false, 'boom') }
		);

		Assert.areEqual(1, batch.totalDeactivated, 'One success should be counted');
		Assert.areEqual(1, batch.failures.size(), 'One failure should be recorded');
		Assert.isTrue(batch.failures[0].contains('boom'), 'The failure should include the error message');
		Assert.isTrue(
			batch.failures[0].startsWith(String.valueOf(users[1].Id)),
			'The failure should start with the user Id'
		);
	}

	@IsTest
	static void buildSummaryBody_withAndWithoutFailures() {
		DeactivateUsersBatch batch = new DeactivateUsersBatch();
		batch.totalEvaluated = 5;
		batch.totalDeactivated = 3;

		Assert.areEqual(
			'Evaluated: 5\nDeactivated: 3\nFailures: 0',
			batch.buildSummaryBody(),
			'No failure section when there are no failures'
		);

		batch.failures.add('005000000000001: boom');
		Assert.areEqual(
			'Evaluated: 5\nDeactivated: 3\nFailures: 1\n\n005000000000001: boom',
			batch.buildSummaryBody(),
			'Failure details should be appended'
		);
	}

	@IsTest
	static void execute_directCall_countsEvaluatedAndDeactivated() {
		Profile p = getTestProfile();
		User dueUser = buildTestUser(p.Id, '5');
		dueUser.Deactivation_Date__c = Date.today().addDays(-1);
		User notDueUser = buildTestUser(p.Id, '6');
		insert new List<User>{ dueUser, notDueUser };

		DeactivateUsersBatch batch = new DeactivateUsersBatch();
		batch.profileRulesByName = new Map<String, Auto_User_Inactive__mdt>{
			TEST_PROFILE => new Auto_User_Inactive__mdt(Label = TEST_PROFILE, From_Last_Login_Date__c = false)
		};

		batch.execute(
			null,
			[
				SELECT Id, Deactivation_Date__c, IsActive, Profile.Name, LastLoginDate
				FROM User
				WHERE Id IN :new List<User>{ dueUser, notDueUser }
			]
		);

		Assert.areEqual(2, batch.totalEvaluated, 'Both users should be evaluated');
		Assert.areEqual(1, batch.totalDeactivated, 'Only the due user should be deactivated');
		Assert.areEqual(0, batch.failures.size(), 'There should be no failures');
	}

	@IsTest
	static void execute_withoutManageUsers_recordsUpdateFailure() {
		Profile p = getTestProfile();
		User operator = buildTestUser(p.Id, '7');
		User dueUser = buildTestUser(p.Id, '8');
		dueUser.Deactivation_Date__c = Date.today().addDays(-1);
		insert new List<User>{ operator, dueUser };

		DeactivateUsersBatch batch = new DeactivateUsersBatch();
		batch.profileRulesByName = new Map<String, Auto_User_Inactive__mdt>{
			TEST_PROFILE => new Auto_User_Inactive__mdt(Label = TEST_PROFILE, From_Last_Login_Date__c = false)
		};
		List<User> scope = [
			SELECT Id, Deactivation_Date__c, IsActive, Profile.Name, LastLoginDate
			FROM User
			WHERE Id = :dueUser.Id
		];

		System.runAs(operator) {
			// A Standard User cannot deactivate other users
			batch.execute(null, scope);
		}

		Assert.areEqual(1, batch.totalEvaluated, 'The user should be evaluated');
		Assert.areEqual(0, batch.totalDeactivated, 'Nothing should be deactivated');
		Assert.areEqual(1, batch.failures.size(), 'The failed update should be recorded');
		Assert.isTrue(batch.failures[0].startsWith(String.valueOf(dueUser.Id)), 'The failure should identify the user');
		Assert.isTrue([SELECT IsActive FROM User WHERE Id = :dueUser.Id].IsActive, 'The user should remain active');
	}

	@IsTest
	static void execute_directCall_skipsUserWithNoMatchingRule() {
		User dueUser = buildTestUser(getTestProfile().Id, '9');
		dueUser.Deactivation_Date__c = Date.today().addDays(-1);
		insert dueUser;

		DeactivateUsersBatch batch = new DeactivateUsersBatch();
		batch.profileRulesByName = new Map<String, Auto_User_Inactive__mdt>();

		batch.execute(
			null,
			[
				SELECT Id, Deactivation_Date__c, IsActive, Profile.Name, LastLoginDate
				FROM User
				WHERE Id = :dueUser.Id
			]
		);

		Assert.areEqual(1, batch.totalEvaluated, 'The user is still counted as evaluated');
		Assert.areEqual(0, batch.totalDeactivated, 'A user with no rule must not be deactivated');
	}

	@IsTest
	static void shouldDeactivate_loginRule_nullNumberOfDays_treatedAsZero() {
		Auto_User_Inactive__mdt rule = new Auto_User_Inactive__mdt(Label = TEST_PROFILE, From_Last_Login_Date__c = true);

		Assert.isTrue(
			new DeactivateUsersBatch().shouldDeactivate(null, Datetime.now().addMinutes(-5), rule),
			'With no day count, any past login is outside the window'
		);
	}

	@IsTest
	static void start_buildsLocatorAndLoadsRules() {
		DeactivateUsersBatch.mockRules = new Map<String, Auto_User_Inactive__mdt>{
			TEST_PROFILE => new Auto_User_Inactive__mdt(Label = TEST_PROFILE, From_Last_Login_Date__c = false)
		};
		DeactivateUsersBatch batch = new DeactivateUsersBatch();

		Database.QueryLocator locator = batch.start(null);

		Assert.areNotEqual(null, locator, 'A query locator should be returned');
		Assert.isTrue(
			batch.profileRulesByName.containsKey(TEST_PROFILE),
			'Rules should be loaded and kept for later chunks'
		);
	}

	@IsTest
	static void start_withoutMockRules_readsDeployedMetadata() {
		DeactivateUsersBatch.mockRules = null;
		DeactivateUsersBatch batch = new DeactivateUsersBatch();

		Assert.areNotEqual(null, batch.start(null), 'start() should work with real metadata');
		Assert.areNotEqual(null, batch.profileRulesByName, 'Rules map should always be set');
	}

	@IsTest
	static void finish_sendsSummaryWithoutError() {
		DeactivateUsersBatch batch = new DeactivateUsersBatch();
		batch.failures.add('005000000000001: boom');

		Test.startTest();
		batch.finish(null);
		Test.stopTest();

		Assert.areEqual(1, batch.failures.size(), 'finish() should not change the recorded failures');
	}
}