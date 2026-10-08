# Automatic Deactivation of Inactive Salesforce Users

## Overview

This solution automates the deactivation of Salesforce users according to per-profile rules. The objective is to improve security, optimize license utilization, and support organizational access management policies.

A scheduled Apex batch job evaluates active users on the profiles you configure. For each profile, a rule deactivates users in one of two ways:

- **Inactivity:** the user has not logged in for a configurable number of days (or has never logged in).
- **Fixed date:** the user's **Deactivation Date** field has passed.

Profiles without a rule are never evaluated, so system administrators, integration users and service accounts can be left out by not creating a rule for their profile. The user the job runs as is never deactivated.

When the job finishes, it emails a summary (users evaluated, users deactivated, and any failures with their error messages) to a configurable list of recipients.

Key features include:

- Configurable inactivity period (X days) per profile.
- Optional fixed deactivation date per user.
- Scheduling through the Apex Scheduler.
- Exclusion of profiles by omission; the running user is always skipped.
- Summary email notifications, including failure details.
- Bulkified processing (200 records per chunk) that supports large orgs.

## The Problem It Solves

Dormant user accounts are a security risk and waste licenses. This solution manages the lifecycle of inactive users automatically, so admins do not have to review and deactivate them by hand.

## Quick Start Guide

### Prerequisites

- A Salesforce org (Sandbox or Developer Edition recommended for first use).
- The user who runs or schedules the job needs the **Manage Users** permission (and the permissions Salesforce requires with it), which the included **Inactive User Deactivator Admin** permission set grants. A scheduled job runs as the user who scheduled it, not as whoever is logged in later.
- To deploy from the command line: the [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`).

### Option 1: 1-Click Install (Recommended for Admins)

Deploy this asset directly to your Sandbox or Developer Edition org without touching the command line.

[![Deploy to Salesforce](https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/deploy.png)](https://githubsfdeploy.herokuapp.com?owner=TrailblazerLabs&repo=Inactive-User-Deactivator)

### Option 2: Install via Salesforce CLI (For Developers)

If you prefer to deploy using a local environment, run the following commands:

1. Clone this repository:
   `git clone https://github.com/TrailblazerLabs/Inactive-User-Deactivator.git`
2. Log in to your target org:
   `sf org login web --alias your-alias`
3. Deploy the metadata:
   `sf project deploy start --target-org your-alias`

### Post-Installation Steps

1. Assign the **Inactive User Deactivator Admin** permission set to the user who will run or schedule the job (and to anyone who sets **Deactivation Date** on users):
   `sf org assign permset --name Inactive_User_Deactivator_Admin --target-org your-alias`
2. Create at least one deactivation rule and set the notification recipients (see [How to Use](#how-to-use)). Until a rule exists, the job evaluates no users.

If the running user lacks Manage Users, the job cannot deactivate anyone. The update for each user fails, nothing is deactivated, and the summary email lists each failed user with its error message under "Failures". If the running user cannot update the `User.IsActive` field at all, the whole chunk is skipped and the email reports "Running user lacks FLS access to update User.IsActive". In either case, assign the permission set and run the job again.

## How to Use

### 1. Define deactivation rules

Create one **Auto User Inactive** custom metadata record (Setup > Custom Metadata Types > Auto User Inactive > Manage Records) for each profile you want to manage. Only users on a profile with a rule are evaluated.

- **Label**: the exact name of the profile the rule applies to. The batch matches users to rules on this value.
- **Record Name**: also the profile name, with spaces and special characters replaced by underscores (Salesforce fills this in from the Label, for example `System_Administrator`). The batch does not use it. Two profiles whose names differ only by spaces or punctuation would produce the same record name, so the second record could not be saved.
- **From Last Login Date** (checked): users are deactivated when their last login is older than **Number of Days**, or they have never logged in.
- **From Last Login Date** (unchecked): users are deactivated once the **Deactivation Date** field on their User record is in the past. **Number of Days** is ignored, and users with no Deactivation Date are left alone.
- **Number of Days**: required. Use a positive whole number (a negative value is treated as its absolute value).

### 2. Set the notification recipients

After each run, a summary email (users evaluated, deactivated and failed) is sent to the addresses in the `User_Deactivation_Notification_List` custom label (Setup > Custom Labels). Enter one or more email addresses separated by commas. Spaces around addresses are ignored.

| Recipients           | Label value                                                   |
| -------------------- | ------------------------------------------------------------- |
| One                  | `admin@example.com`                                           |
| Several              | `admin@example.com,security@example.com`                      |
| Several, with spaces | `admin@example.com, security@example.com, it-ops@example.com` |

Do not use semicolons or line breaks as separators. A blank value turns the email off.

### 3. Run the job

Run it once on demand from Developer Console > Execute Anonymous:

```apex
Database.executeBatch(new DeactivateUsersBatch(), 200);
```

Or schedule it to run daily at 2 AM:

```apex
System.schedule('Deactivate Inactive Users', '0 0 2 * * ?', new DeactivateUsersBatch());
```

The user the job runs as is never deactivated. Failures for individual users (for example, a user who cannot be deactivated) do not stop the job; they are listed in the summary email.

## About the Creator

Built by [@houssamsaoudy](https://github.com/houssamsaoudy) as part of the Trailblazer Labs Builder in Residence Cohort.
