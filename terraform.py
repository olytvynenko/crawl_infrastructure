from python_terraform import *

t = Terraform(working_dir='.')


def destroy():
    # t.plan(capture_output=False)
    return_code, stdout, stderr = t.destroy(input=False, capture_output=False)


if __name__ == "__main__":
    destroy()
