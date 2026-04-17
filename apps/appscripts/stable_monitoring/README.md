# Stable Monitoring Dashboard guide

> **Runtime:** This script runs in Google Apps Script, not Node.js. Paste the contents of `testray_stable_passrate.js` into an Apps Script project bound to the target Google Sheet.
>
> **Related:** Shared Apps Script helpers live in [`apps/appscripts/_lib/`](../_lib/).

This guide provides the necessary steps to maintain and update the **Stable Monitoring dashboard**. It covers the data pipeline from the Testray API into Google Sheets and finally into Looker Studio.

---

## 🔄 Data Maintenance & Refreshing

### 1. Daily Data Refresh
To pull the latest build results from Testray:
* Open the Google Sheet.
* In the top menu, click **🔄 Testray** > **🔄 Refresh Stable Data**.
* **Initial Authorization**: For the first run, Google will ask for Authorization. This is to authorize the script to run on the current sheet. Once authorized, click **Refresh Stable Data** again to actually start the process.
* **Authentication**: The script will prompt for a **Client ID** and **Client Secret**. Input the team's Testray API credentials.
* Wait for the "Fetch Complete" toast notification. This automatically updates the timeline and failure logs.

### 2. Handling CI Failures/Testing
If CI testing builds need to be taken out of the data, the builds need to be 'tagged' to remove them from the metrics:
* Go to the **`Stable_timeline`** tab.
* Locate the specific Build ID(s) affected by infrastructure issues.
* In the **Comment** column, type **"CI"** (e.g., "CI Issue", "CI failure").
* Go to the menu: **🔄 Testray** > **♻️ Recalculate Metrics (Removes "CI" builds)**.
* This process wipes those builds from the failure rates and hides them from Looker Studio globally.

### 3. Syncing Looker Studio
Looker Studio caches data for performance. After recalculating in Sheets:
* Open the Looker Studio Dashboard.
* Click the **three dots (⋮)** in the top right corner.
* Select **Refresh Data**.

---

## 📊 Google Sheet Details

| Tab Name | Purpose | Maintenance |
| :--- | :--- | :--- |
| **Stable_fetch** | Raw dump of every build from the Testray API. | Managed by Script. |
| **Stable_timeline** | Clean log of builds since March 23rd. | **Manual:** Add "CI" tags here. |
| **Stable_failedTests** | Detailed log of every test failure per build. | Managed by Script. |
| **Stable_testMetrics** | Pre-calculated failure rates (Pre vs. Post Change). | Managed by Script. |
| **Stable_weeklyMetrics** | Pre-calculated weekly failure rates for trend lines. | Managed by Script. |

---

## 📈 Looker Studio Setup
To ensure CI builds are hidden across all charts, a **Global Page Filter** is applied:

1. **Data Sources**: If new columns are added to Sheets, go to *Resource > Manage added data sources > Edit > Refresh Fields*.
2. **The CI Filter**: Every chart or page should have a filter set to:
   * `Include` > `Ignore_Build` > `Is null`.
   * *Rationale*: The script marks bad builds as "CI" and leaves good builds as `null`. Filtering for `null` ensures only valid product data is displayed.

---

## 🛠 Troubleshooting
* **"Invalid Formula" in Looker**: This usually happens if you try to do math inside Looker using blended data. Always perform new calculations in the Apps Script and output a new "Flat" column to a sheet instead.
* **Script Authorization**: If the script fails to run, ensure the user has "Editor" access to the sheet and has authorized the script to run under their Google account.
* **Missing Build IDs**: The timeline tab only pulls builds dated **March 23, 2026** or later. If a build is missing, check if it has been fetched into `Stable_fetch` first. If build IDs prior to March 23 needs to be added, adjust this in the App script.