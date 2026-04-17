#!/usr/bin/env python
import os
import sys
import git
from jira import JIRAError

from release_constants import URLs

sys.path.append(os.path.join(sys.path[0], '..', 'utils'))

from liferay_utils.jira_utils.jira_helpers import LIFERAY_JIRA_BROWSE_URL
from liferay_utils.jira_utils.jira_helpers import initialize_subtask_patch_release
from liferay_utils.jira_utils.jira_liferay import get_jira_connection


def get_lps_from_local_repo(jira, repo_path, start_hash, end_hash, release='', lpd_ticket=''):
    liferay_portal_ee_repo = git.Repo(repo_path)

    print("Retrieving git info for Release " + release + "...")

    of_interest = liferay_portal_ee_repo.git.log(start_hash + ".." + end_hash, "--pretty=format:%H")

    individual_commit_hashes = of_interest.split('\n')
    lps_list = []
    revered_list = []
    no_bugs_list = []

    for commit_hash in individual_commit_hashes:
        message = liferay_portal_ee_repo.commit(commit_hash).message
        lps = message.split(' ')[0].split('\n')[0]
        if message.lower().find('revert') != -1:
            revered_list.append(URLs.Liferay_repo_URL + '/commit/' + commit_hash)
        elif (lps not in lps_list) and ('-' in lps):
            lps_list.append(lps)

    for lps in lps_list:
        try:
            lps_type = jira.issue(lps, fields='issuetype').fields.issuetype
        except JIRAError as err:
            lps_list.remove(lps)
            print("Error for ticket: " + lps + ": " + err.args[0])
            continue
        if lps_type.name != 'Bug':
            lps_list.remove(lps)
            no_bugs_list.append(LIFERAY_JIRA_BROWSE_URL + lps)

    if lpd_ticket:
        print("Creating sub-tasks")

        parent_lps = jira.issue(lpd_ticket, fields=['id'])
        for lps_id in lps_list:
            sub_task = initialize_subtask_patch_release(parent_lps, lps_id + ' - ' + release)
            new_issue = jira.create_issue(fields=sub_task)
            try:
                jira.create_issue_link(
                    type="relates",
                    inwardIssue=new_issue.key,
                    outwardIssue=lps_id,
                )
            except JIRAError as err:
                print("Error creating ticket: " + lps_id + ": " + err.args[0])
                continue

    print(" List of Stories:")
    print(*lps_list, sep="\n")
    print("\n\n List of reverted commits:")
    print(*revered_list, sep="\n")
    print("\n\n List of issues that are not bugs:")
    print(*no_bugs_list, sep="\n")


if __name__ == '__main__':
    try:
        path = sys.argv[1]
    except IndexError:
        print("Please provide a local path to the report")
        exit()

    try:
        first_hash = sys.argv[2]
    except IndexError:
        print("Please provide a hash to start")
        exit()

    try:
        final_hash = sys.argv[3]
    except IndexError:
        print("Please provide a hash to finish")
        exit()

    try:
        next_release = sys.argv[4]
    except IndexError:
        next_release = ""

    try:
        lpd = sys.argv[5]
    except IndexError:
        lpd = ""

    jira_connection = get_jira_connection()
    get_lps_from_local_repo(jira_connection, path, first_hash, final_hash, next_release, lpd)
