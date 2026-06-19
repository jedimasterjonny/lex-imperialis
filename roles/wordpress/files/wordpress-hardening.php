<?php
/*
 * Plugin Name: Hardening
 * Description: Must-use tweaks that suppress version disclosure.
 */

// Drop the <meta name="generator"> tag WordPress prints into every page head.
remove_action( 'wp_head', 'wp_generator' );
