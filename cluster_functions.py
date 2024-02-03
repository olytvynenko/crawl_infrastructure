from python_terraform import *

t = Terraform(working_dir='.')


class ClusterFunctions:

    @staticmethod
    def create(regions=None):
        if regions is None:
            return
        for workspace in regions:
            subprocess.run(['terraform', 'workspace', 'select', workspace], cwd='./crawl_infrastructure')
            result = subprocess.run(['terraform', 'apply', '-auto-approve'], cwd='./crawl_infrastructure')
            print(result)

    @staticmethod
    def destroy(regions=None):
        if regions is None:
            return
        for workspace in regions:
            subprocess.run(['terraform', 'workspace', 'select', workspace], cwd='./crawl_infrastructure')
            result = subprocess.run(['terraform', 'destroy', '-auto-approve'], cwd='./crawl_infrastructure')
            print(result)


if __name__ == "__main__":
    pass
