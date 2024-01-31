from python_terraform import *

t = Terraform(working_dir='.')


def destroy():
    # t.plan(capture_output=False)
    return_code, stdout, stderr = t.destroy(input=False, capture_output=False)


if __name__ == "__main__":
    tf = Terraform(working_dir='./crawl_infrastructure')
    for workspace in ["nv", "oregon", "ohio", "nc"]:
        tf.set_workspace(workspace)
        tf.apply(skip_plan=True)
