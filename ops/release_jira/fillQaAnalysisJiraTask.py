#!/usr/bin/env python
import sys

from getLpsFromLocalRepo import get_lps_from_local_repo
from release_constants import Roles, Filter, FileName
from liferay_utils.jira_utils.jira_constants import Transition, Status
from liferay_utils.jira_utils.jira_helpers import get_all_issues
from liferay_utils.jira_utils.jira_liferay import get_jira_connection


def fill_qa_analysis_jira_task(jira, repo_path, start_hash, end_hash, release_version=''):
    if release_version:
        print("Get task from " + release_version)
        jql = Filter.QA_Analysis_for_release.format(release_version=release_version)
        qa_analysis_tasks = get_all_issues(jira, jql, ["key", "status"])
        if len(qa_analysis_tasks) == 1:
            parent_task = qa_analysis_tasks[0]
            parent_task_key = parent_task.key
            parent_task_status = parent_task.get_field("status").name
            get_lps_from_local_repo(jira, repo_path, start_hash, end_hash, release_version, parent_task_key)
            file_name = FileName.Parent_task_file_name
            with open(file_name, 'w') as archivo:
                archivo.write(parent_task_key)
            jira.assign_issue(parent_task_key, Roles.Release_lead)
            if parent_task_status == Status.Open:
                jira.transition_issue(parent_task_key, transition=Transition.Selected_for_development)
                jira.transition_issue(parent_task_key, transition=Transition.In_Progress)


if __name__ == '__main__':
    path = ''
    first_hash = ''
    final_hash = ''
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
        release = sys.argv[4]
    except IndexError:
        release = ""
    jira_connection = get_jira_connection()
    fill_qa_analysis_jira_task(jira_connection, path, first_hash, final_hash, release)
