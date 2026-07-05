<?php
/*
 * Plugin Name: Hardening
 * Description: Must-use tweaks that suppress version and user disclosure and neuter XML-RPC pingback.
 */

// Drop the <meta name="generator"> tag WordPress prints into every page head.
remove_action( 'wp_head', 'wp_generator' );

// Deny anonymous user enumeration through the REST API: with no logged-in user,
// drop the users collection and single-user routes so /wp-json/wp/v2/users 404s
// instead of listing every author's login slug. wp-admin keeps them (the editor
// needs the author list) because there the request is authenticated.
add_filter( 'rest_endpoints', function ( $endpoints ) {
	if ( is_user_logged_in() ) {
		return $endpoints;
	}
	unset( $endpoints['/wp/v2/users'], $endpoints['/wp/v2/users/(?P<id>[\d]+)'] );
	return $endpoints;
} );

// Block the ?author=N probe: anonymous author queries — and the /author/<slug>/
// archives they resolve to — redirect home before redirect_canonical can leak
// the username in the URL. Priority 0 runs this ahead of that core handler.
add_action( 'template_redirect', function () {
	if ( is_user_logged_in() ) {
		return;
	}
	if ( is_author() || isset( $_GET['author'] ) ) {
		wp_safe_redirect( home_url( '/' ) );
		exit;
	}
}, 0 );

// Strip the pingback vector while leaving XML-RPC itself enabled for Jetpack:
// drop the pingback methods and the X-Pingback header that advertises them.
add_filter( 'xmlrpc_methods', function ( $methods ) {
	unset( $methods['pingback.ping'], $methods['pingback.extensions.getPingbacks'] );
	return $methods;
} );

add_filter( 'wp_headers', function ( $headers ) {
	unset( $headers['X-Pingback'] );
	return $headers;
} );
