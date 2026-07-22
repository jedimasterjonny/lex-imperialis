"""Shared constants for the arr verify suite.

The suite runs on the controller and cannot read the play's vars, so the
converge/defaults values it needs are duplicated here (kept in sync by hand).
"""

# roles/arr/defaults/main.yml: arr_domain = caddy_domain | default('home.arpa').
# The converge sets no caddy_domain, so it falls to the caddy role's default.
DOMAIN = "home.arpa"
# roles/arr/defaults/main.yml: arr_data_root
DATA_ROOT = "/nfs/administratum/scriptorum"
# roles/arr/vars/main.yml: arr_group
ARR_GROUP = "arr"
# roles/arr/defaults/main.yml: arr_gid (the NAS's shared arr gid)
ARR_GID = 65537
# roles/arr/defaults/main.yml: arr_beets_metric_textfile_dir
TEXTFILE_DIR = "/var/lib/node_exporter/textfile_collector"
