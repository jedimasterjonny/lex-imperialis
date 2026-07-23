"""Shared constants for the wordpress verify suite.

The suite runs on the controller and cannot read the play's vars, so the
converge/defaults values it needs are duplicated here (kept in sync by hand).
"""

# roles/wordpress/molecule/default/converge.yml: wordpress_domains[0]
DOMAIN = "wordpress.home.arpa"
# roles/wordpress/defaults/main.yml: wordpress_textfile_dir
TEXTFILE_DIR = "/var/lib/node_exporter/textfile_collector"
# roles/wordpress/defaults/main.yml: wordpress_db_name
DB_NAME = "wordpress"
