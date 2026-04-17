class FileName:
    Parent_task_file_name = "PARENT_TASK.txt"


class Filter:
    QA_Analysis_for_release = ('project = "PUBLIC - Liferay Product Delivery" AND summary ~ "{release_version} QA '
                               'Analysis"')
    Build_for_release = 'project = "PUBLIC - Liferay Product Delivery" AND summary ~ "{release_version} Build"'


class Roles:
    Release_lead = 'bahar.turk'


class URLs:
    Liferay_repo_URL = 'https://github.com/liferay/liferay-portal-ee/'
