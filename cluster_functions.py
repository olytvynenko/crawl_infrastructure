import subprocess

from python_terraform import *
from exceptions import ParameterValidationError
from classes import InstanceLevel

t = Terraform(working_dir='.')


class ClusterFunctions:

    @staticmethod
    def create(regions=None):
        if regions is None:
            raise ParameterValidationError(f"regions = {regions}")
        for workspace in regions:
            subprocess.run(['terraform', 'workspace', 'select', workspace], cwd='./crawl_infrastructure')
            result = subprocess.run(['terraform', 'apply', '-auto-approve'], cwd='./crawl_infrastructure')
            print(result)

    @staticmethod
    def destroy(regions=None):
        if regions is None:
            raise ParameterValidationError(f"regions = {regions}")
        for workspace in regions:
            subprocess.run(['terraform', 'workspace', 'select', workspace], cwd='./crawl_infrastructure')
            result = subprocess.run(['terraform', 'destroy', '-auto-approve'], cwd='./crawl_infrastructure')
            print(result)

    @staticmethod
    def set_workers_level(workspace=None, level=InstanceLevel.inst4):
        if not isinstance(level, InstanceLevel):
            raise ParameterValidationError("level must be of InstanceLevel enum type")
        levels = {InstanceLevel.inst4: "inst4", InstanceLevel.inst8: "inst8", InstanceLevel.inst16: "inst16"}
        if workspace is None:
            raise ParameterValidationError(f"regions = {workspace}")
        for workspace in workspace:
            subprocess.run(['terraform', 'workspace', 'select', workspace], cwd='./crawl_infrastructure')
            import json
            with open('./crawl_infrastructure/terraform.tfvars.json.bak', 'r') as fr:
                variables = json.loads(fr.read())
                variables['cluster_level'] = levels[level]
            with open('./crawl_infrastructure/terraform.tfvars.json', 'w') as fw:
                fw.write(json.dumps(variables, indent=4))
            subprocess.check_output(['terraform', 'apply', '-auto-approve'], cwd='./crawl_infrastructure')


if __name__ == "__main__":
    ClusterFunctions.set_workers_level(["nv"], "inst4")
