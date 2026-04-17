#!/usr/bin/env python
import os
import sys

sys.path.append(os.path.join(sys.path[0], '..', 'utils'))

from release_constants import Filter, Roles
from liferay_utils.jira_utils.jira_constants import Status, Transition
from liferay_utils.jira_utils.jira_helpers import get_all_issues
from liferay_utils.jira_utils.jira_liferay import get_jira_connection


def update_build_subtask(jira, url_to_release_candidate, release_version):
    jql = Filter.Build_for_release.format(release_version=release_version)
    qa_analysis_tasks = get_all_issues(jira, jql, ["key", "status"])
    if len(qa_analysis_tasks) == 1:
        parent_task = qa_analysis_tasks[0]
        parent_task_key = parent_task.key
        parent_task_status = parent_task.get_field("status").name
        jira.assign_issue(parent_task_key, Roles.Release_lead)
        jira.add_comment(parent_task_key, "Release candidate: " + url_to_release_candidate)
        if parent_task_status == Status.Open:
            jira.transition_issue(parent_task_key, transition=Transition.Selected_for_development)
            jira.transition_issue(parent_task_key, transition=Transition.In_Progress)


if __name__ == '__main__':
    try:
        url_to_release = sys.argv[1]
    except IndexError:
        print("Please provide a URL to release candidate")
        exit()

    try:
        next_release = sys.argv[2]
    except IndexError:
        print("Please provide the next release")
        exit()

    jira_connection = get_jira_connection()
    update_build_subtask(jira_connection, url_to_release, next_release)
