from python_terraform import *
from exceptions import ParameterValidationError
from classes import InstanceLevel
import json


class ClusterFunctions:

    def __init__(self, wd=None):
        if wd is None:
            raise ParameterValidationError("wd must be set to working directory")
        self.working_directory = wd

    def create(self, workspaces=None):
        if workspaces is None:
            raise ParameterValidationError(f"workspaces = {workspaces}")
        for workspace in workspaces:
            subprocess.run(['terraform', 'workspace', 'select', workspace], cwd=self.working_directory)
            result = subprocess.run(['terraform', 'apply', '-auto-approve'], cwd=self.working_directory)
            print(result)

    def destroy(self, workspaces=None):
        if workspaces is None:
            raise ParameterValidationError(f"workspaces = {workspaces}")
        for workspace in workspaces:
            subprocess.run(['terraform', 'workspace', 'select', workspace], cwd=self.working_directory)
            result = subprocess.run(['terraform', 'destroy', '-auto-approve'], cwd=self.working_directory)
            print(result)

    def set_workers_level(self, workspace=None, level=InstanceLevel.inst4):
        if not isinstance(level, InstanceLevel):
            raise ParameterValidationError("level must be of InstanceLevel enum type")
        levels = {InstanceLevel.inst4: "inst4", InstanceLevel.inst8: "inst8", InstanceLevel.inst16: "inst16"}
        if workspace is None:
            raise ParameterValidationError(f"workspace = {workspace}")
        for workspace in workspace:
            subprocess.run(['terraform', 'workspace', 'select', workspace], cwd=self.working_directory)
            with open(f'{self.working_directory}/terraform.tfvars.json.bak', 'r') as fr:
                variables = json.loads(fr.read())
                variables['cluster_level'] = levels[level]
            with open(f'{self.working_directory}/terraform.tfvars.json', 'w') as fw:
                fw.write(json.dumps(variables, indent=4))
            subprocess.check_output(['terraform', 'apply', '-auto-approve'], cwd=self.working_directory)


if __name__ == "__main__":
    # workspaces = ["ohio", "oregon", "nc", "nv"]
    # workspaces = ["oregon", "nc"]
    workspaces = ["oregon"]
    cf = ClusterFunctions('./crawl_infrastructure')
    cf.destroy(workspaces)
