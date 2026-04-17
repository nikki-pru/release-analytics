#!/usr/bin/env python
import os
import sys
import git

sys.path.append(os.path.join(sys.path[0], '..', 'utils'))

from liferay_utils.jira_utils.jira_liferay import get_jira_connection


def get_lps_from_local_repo(jira, repo_path, start_hash, end_hash):
    liferay_portal_ee_repo = git.Repo(repo_path)

    print("Retrieving git info...")

    of_interest = liferay_portal_ee_repo.git.log(start_hash + ".." + end_hash, "--pretty=format:%H")

    individual_commit_hashes = of_interest.split('\n')
    lps_list = []

    for commit_hash in individual_commit_hashes:
        message = liferay_portal_ee_repo.commit(commit_hash).message
        lps = message.split(' ')[0].split('\n')[0]
        if (lps not in lps_list) and ('-' in lps):
            lps_list.append(lps)

    print(" List of Stories:")
    print(*lps_list, sep="\n")
    print("\n\n Total issues: " + str(len(lps_list)))


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

    jira_connection = get_jira_connection()
    get_lps_from_local_repo(jira_connection, path, first_hash, final_hash)
