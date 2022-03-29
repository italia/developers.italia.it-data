import os
import pathlib
import shutil
import yaml
import json
from github import Github
from git import Repo


REPO_FOLDER = "repositories"
TEMP_REPO_FOLDER = "temp_repositories"
SOFTWARES_FOLDER = "softwares"

pathlib.Path(REPO_FOLDER).mkdir(parents=True, exist_ok=True)

github_client = Github(os.environ.get("GH_ACCESS_TOKEN"))


def _write_json_file(software_name, payload):
    dest = os.path.join(SOFTWARES_FOLDER, f"{software_name}.json")
    with open(dest, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=4)


def _get_data_from_software(base_directory, software, provider, softwares):
    desc_yml_path = os.path.join(base_directory, "desc.yml")
    if os.path.isfile(desc_yml_path):
        if software not in softwares:
            softwares[software] = {}
            softwares[software]["providers"] = {}
        if provider not in softwares[software]["providers"]:
            softwares[software]["providers"][provider] = {}
        with open(desc_yml_path, "r") as stream:
            try:
                yaml_data = yaml.safe_load(stream)
                softwares[software]["providers"][provider] = yaml_data[
                    "deployment_option"
                ]
            except yaml.YAMLError as exc:
                print(exc)


def fetch_providers():
    softwares = {}
    if os.path.exists(TEMP_REPO_FOLDER):
        shutil.rmtree(TEMP_REPO_FOLDER)
    if os.path.exists(SOFTWARES_FOLDER):
        shutil.rmtree(SOFTWARES_FOLDER)
    pathlib.Path(TEMP_REPO_FOLDER).mkdir(parents=True, exist_ok=True)
    pathlib.Path(SOFTWARES_FOLDER).mkdir(parents=True, exist_ok=True)
    for repo in github_client.search_repositories("org:w0rkb3nch"):
        if repo.name.startswith("cloud-"):
            print(f"🗃 Cloning {repo.clone_url}..", end="")
            software_direcotry = os.path.join(REPO_FOLDER, repo.name)
            temp_software_directory = os.path.join(TEMP_REPO_FOLDER, repo.name)
            Repo.clone_from(repo.clone_url, temp_software_directory)
            shutil.rmtree(os.path.join(temp_software_directory, ".git"))
            shutil.copytree(
                temp_software_directory, software_direcotry, dirs_exist_ok=True
            )
            print("Done!")
            print(f"📃 Fetching data from {repo.name}..", end="")
            for software in os.listdir(software_direcotry):
                _get_data_from_software(
                    os.path.join(software_direcotry, software),
                    software,
                    repo.name,
                    softwares,
                )
            print("Done!")

    softwares_collection = []
    for software_name, software_data in softwares.items():
        software = {"slug": software_name, **software_data}
        _write_json_file(software_name, software)
        softwares_collection.append(software)
    _write_json_file("all", softwares_collection)


fetch_providers()
