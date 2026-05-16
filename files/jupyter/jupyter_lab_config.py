# files/jupyter/jupyter_lab_config.py
# Jupyter Lab config for thesis-infra development.
# Bound to 127.0.0.1; access via SSH tunnel (VSCode auto-forwards).

c = get_config()  # noqa

c.ServerApp.ip = '127.0.0.1'
c.ServerApp.port = 8889                # configurable in all.yml jupyter_port
c.ServerApp.open_browser = False
c.ServerApp.allow_root = True
c.ServerApp.root_dir = '/root/thesis-infra'
c.ServerApp.allow_origin = '*'

# SSH tunnel is the security boundary; disable token/password auth
c.ServerApp.token = ''
c.ServerApp.password = ''
c.ServerApp.disable_check_xsrf = True

c.LabApp.default_url = '/lab/tree/notebooks'

c.MappingKernelManager.cull_idle_timeout = 3600
c.MappingKernelManager.cull_interval = 300
