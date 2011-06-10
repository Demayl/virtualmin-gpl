
sub init_ssl
{
$feature_depends{'ssl'} = [ 'web', 'dir' ];
$default_web_sslport = $config{'web_sslport'} || 443;
}

# check_warnings_ssl(&dom, &old-domain)
# An SSL website should have either a private IP, or private port, UNLESS
# the clashing domain's cert can be used for this domain.
sub check_warnings_ssl
{
local ($d, $oldd) = @_;
local $tmpl = &get_template($d->{'template'});
local $defport = $tmpl->{'web_sslport'} || 443;
local $port = $d->{'web_sslport'} || $defport;

# Check if Apache supports SNI, which makes clashing certs not so bad
local @dirs = &list_apache_directives();
local ($sni) = grep { lc($_->[0]) eq lc("SSLStrictSNIVHostCheck") } @dirs;

if ($d->{'virt'}) {
	# Has a private IP
	return undef;
	}
elsif ($port != $defport) {
	# Has a private port
	return undef;
	}
else {
	# Neither .. but we can still do SSL, if there are no other domains
	# with SSL on the same IP
	local ($sslclash) = grep { $_->{'ip'} eq $d->{'ip'} &&
				   $_->{'ssl'} &&
				   $_->{'id'} ne $d->{'id'}} &list_domains();
	if ($sslclash && (!$oldd || !$oldd->{'ssl'})) {
		# Clash .. but is the cert OK?
		if (!&check_domain_certificate($d->{'dom'}, $sslclash)) {
			local @certdoms = &list_domain_certificate($sslclash);
			return &text($sni ? 'setup_edepssl5sni'
					  : 'setup_edepssl5', $d->{'ip'},
				join(", ", map { "<tt>$_</tt>" } @certdoms),
				$sslclash->{'dom'});
			}
		else {
			return undef;
			}
		}
	# Check for <virtualhost> on the IP, if we are turning on SSL
	if (!$oldd || !$oldd->{'ssl'}) {
		&require_apache();
		local $conf = &apache::get_config();
		foreach my $v (&apache::find_directive_struct("VirtualHost",
							      $conf)) {
			local ($vip, $vport) = split(/:/, $v->{'words'}->[0]);
			if ($vip eq $d->{'ip'} && $vport == $port) {
				return &text('setup_edepssl4',
					     $d->{'ip'}, $port);
				}
			}
		}
	return undef;
	}
}

# setup_ssl(&domain)
# Creates a website with SSL enabled, and a private key and cert it to use.
sub setup_ssl
{
local $tmpl = &get_template($_[0]->{'template'});
local $web_sslport = $_[0]->{'web_sslport'} || $tmpl->{'web_sslport'} || 443;
&require_apache();
&obtain_lock_web($_[0]);
local $conf = &apache::get_config();

# Find out if this domain will share a cert with another
local $chained;
local ($sslclash) = grep { $_->{'ip'} eq $_[0]->{'ip'} &&
			   $_->{'ssl'} &&
			   $_->{'id'} ne $_[0]->{'id'} &&
			   !$_->{'ssl_same'} } &list_domains();
if ($sslclash && &check_domain_certificate($_[0]->{'dom'}, $sslclash)) {
	# Yes - so just use it. In practice this doesn't really matter, as
	# Apache will pick up the first domain's cert anyway.
	$_[0]->{'ssl_cert'} = $sslclash->{'ssl_cert'};
	$_[0]->{'ssl_key'} = $sslclash->{'ssl_key'};
	$_[0]->{'ssl_same'} = $sslclash->{'id'};
	$chained = &get_chained_certificate_file($sslclash);
	$_[0]->{'ssl_chain'} = $chained;
	}

# Create a self-signed cert and key, if needed
$_[0]->{'ssl_cert'} ||= &default_certificate_file($_[0], 'cert');
$_[0]->{'ssl_key'} ||= &default_certificate_file($_[0], 'key');
if (!-r $_[0]->{'ssl_cert'} && !-r $_[0]->{'ssl_key'}) {
	# Need to do it
	local $temp = &transname();
	&$first_print($text{'setup_openssl'});
	&lock_file($_[0]->{'ssl_cert'});
	&lock_file($_[0]->{'ssl_key'});
	local $err = &generate_self_signed_cert(
		$_[0]->{'ssl_cert'}, $_[0]->{'ssl_key'}, undef, 1825,
		undef, undef, undef, $_[0]->{'owner'}, undef,
		"*.$_[0]->{'dom'}", $_[0]->{'emailto'}, undef, $_[0]);
	if ($err) {
		&$second_print(&text('setup_eopenssl', $err));
		return 0;
		}
	else {
		&set_certificate_permissions($_[0], $_[0]->{'ssl_cert'});
		&set_certificate_permissions($_[0], $_[0]->{'ssl_key'});
		if (&has_command("chcon")) {
			&execute_command("chcon -R -t httpd_config_t ".quotemeta($_[0]->{'ssl_cert'}).">/dev/null 2>&1");
			&execute_command("chcon -R -t httpd_config_t ".quotemeta($_[0]->{'ssl_key'}).">/dev/null 2>&1");
			}
		&$second_print($text{'setup_done'});
		}
	&unlock_file($_[0]->{'ssl_cert'});
	&unlock_file($_[0]->{'ssl_key'});
	}

# Add NameVirtualHost if needed, and if there is more than one SSL site on
# this IP address
local $nvstar = &add_name_virtual($_[0], $conf, $web_sslport);

# Add a Listen directive if needed
&add_listen($_[0], $conf, $web_sslport);

# Find directives in the non-SSL virtualhost, for copying
&$first_print($text{'setup_ssl'});
local ($virt, $vconf) = &get_apache_virtual($_[0]->{'dom'},
					    $_[0]->{'web_port'});
if (!$virt) {
	&$second_print($text{'setup_esslcopy'});
	return 0;
	}
local $srclref = &read_file_lines($virt->{'file'});

# Double-check cert and key
local $certdata = &read_file_contents($_[0]->{'ssl_cert'});
local $keydata = &read_file_contents($_[0]->{'ssl_key'});
local $err = &validate_cert_format($certdata, 'cert');
if ($err) {
	&$second_print(&text('setup_esslcert', $err));
	return 0;
	}
local $err = &validate_cert_format($keydata, 'key');
if ($err) {
	&$second_print(&text('setup_esslkey', $err));
	return 0;
	}
if ($_[0]->{'ssl_ca'}) {
	local $cadata = &read_file_contents($_[0]->{'ssl_ca'});
	local $err = &validate_cert_format($cadata, 'ca');
	if ($err) {
		&$second_print(&text('setup_esslca', $err));
		return 0;
		}
	}
local $err = &check_cert_key_match($certdata, $keydata);
if ($err) {
	&$second_print(&text('setup_esslmatch', $err));
	return 0;
	}

# Add the actual <VirtualHost>
local $f = $virt->{'file'};
local $lref = &read_file_lines($f);
local @ssldirs = &apache_ssl_directives($_[0], $tmpl);
push(@$lref, "<VirtualHost ".&get_apache_vhost_ips($_[0], 0, $web_sslport).">");
push(@$lref, @$srclref[$virt->{'line'}+1 .. $virt->{'eline'}-1]);
push(@$lref, @ssldirs);
push(@$lref, "</VirtualHost>");
&flush_file_lines($f);

# Update the non-SSL virtualhost to include the port number, to fix old
# hosts that were missing the :80
local $lref = &read_file_lines($virt->{'file'});
if (!$_[0]->{'name'} && $lref->[$virt->{'line'}] !~ /:\d+/) {
	$lref->[$virt->{'line'}] =
		"<VirtualHost $_[0]->{'ip'}:$_[0]->{'web_port'}>";
	&flush_file_lines($virt->{'file'});
	}
undef(@apache::get_config_cache);

# Add this IP and cert to Webmin/Usermin's SSL keys list
if ($tmpl->{'web_webmin_ssl'} && $d->{'virt'}) {
	&setup_ipkeys($_[0], \&get_miniserv_config, \&put_miniserv_config,
		      \&restart_webmin);
	}
if ($tmpl->{'web_usermin_ssl'} && &foreign_installed("usermin") &&
    $d->{'virt'}) {
	&foreign_require("usermin", "usermin-lib.pl");
	&setup_ipkeys($_[0], \&usermin::get_usermin_miniserv_config,
		      \&usermin::put_usermin_miniserv_config,
		      \&restart_usermin);
	}

# Copy chained CA cert in from domain with same IP, if any
$_[0]->{'web_sslport'} = $web_sslport;
if ($chained) {
	&save_chained_certificate_file($_[0], $chained);
	}

&release_lock_web($_[0]);
&$second_print($text{'setup_done'});
&register_post_action(\&restart_apache, 1);
}

# modify_ssl(&domain, &olddomain)
sub modify_ssl
{
local $rv = 0;
&require_apache();
&obtain_lock_web($_[0]);

# Get objects for SSL and non-SSL virtual hosts
local ($virt, $vconf, $conf) = &get_apache_virtual($_[1]->{'dom'},
                                                   $_[1]->{'web_sslport'});
local ($nonvirt, $nonvconf) = &get_apache_virtual($_[0]->{'dom'},
						  $_[0]->{'web_port'});
local $tmpl = &get_template($_[0]->{'template'});

if ($_[0]->{'ip'} ne $_[1]->{'ip'} ||
    $_[0]->{'ip6'} ne $_[1]->{'ip6'} ||
    $_[0]->{'virt6'} != $_[1]->{'virt6'} ||
    $_[0]->{'web_sslport'} != $_[1]->{'web_sslport'}) {
	# IP address or port has changed .. update VirtualHost
	&$first_print($text{'save_ssl'});
	if (!$virt) {
		&$second_print($text{'delete_noapache'});
		goto VIRTFAILED;
		}
	&add_listen($_[0], $conf, $_[0]->{'web_sslport'});
	local $lref = &read_file_lines($virt->{'file'});
	$lref->[$virt->{'line'}] =
		"<VirtualHost ".
		&get_apache_vhost_ips($_[0], 0, $_[0]->{'web_sslport'}).">";
	&flush_file_lines();
	$rv++;
	undef(@apache::get_config_cache);
	($virt, $vconf, $conf) = &get_apache_virtual($_[1]->{'dom'},
					      	     $_[1]->{'web_sslport'});
	&$second_print($text{'setup_done'});
	}
if ($_[0]->{'home'} ne $_[1]->{'home'}) {
	# Home directory has changed .. update any directives that referred
	# to the old directory
	&$first_print($text{'save_ssl3'});
	if (!$virt) {
		&$second_print($text{'delete_noapache'});
		goto VIRTFAILED;
		}
	local $lref = &read_file_lines($virt->{'file'});
	for($i=$virt->{'line'}; $i<=$virt->{'eline'}; $i++) {
		$lref->[$i] =~ s/\Q$_[1]->{'home'}\E/$_[0]->{'home'}/g;
		}
	&flush_file_lines();
	$rv++;
	undef(@apache::get_config_cache);
	($virt, $vconf, $conf) = &get_apache_virtual($_[1]->{'dom'},
					      	     $_[1]->{'web_sslport'});
	&$second_print($text{'setup_done'});
	}
if ($_[0]->{'proxy_pass_mode'} == 1 &&
    $_[1]->{'proxy_pass_mode'} == 1 &&
    $_[0]->{'proxy_pass'} ne $_[1]->{'proxy_pass'}) {
	# This is a proxying forwarding website and the URL has
	# changed - update all Proxy* directives
	&$first_print($text{'save_ssl6'});
	if (!$virt) {
		&$second_print($text{'delete_noapache'});
		goto VIRTFAILED;
		}
	local $lref = &read_file_lines($virt->{'file'});
	for($i=$virt->{'line'}; $i<=$virt->{'eline'}; $i++) {
		if ($lref->[$i] =~ /^\s*ProxyPass(Reverse)?\s/) {
			$lref->[$i] =~ s/$_[1]->{'proxy_pass'}/$_[0]->{'proxy_pass'}/g;
			}
		}
	&flush_file_lines();
	$rv++;
	&$second_print($text{'setup_done'});
	}
if ($_[0]->{'proxy_pass_mode'} != $_[1]->{'proxy_pass_mode'}) {
	# Proxy mode has been enabled or disabled .. copy all directives from
	# non-SSL site
	local $mode = $_[0]->{'proxy_pass_mode'} ||
		      $_[1]->{'proxy_pass_mode'};
	&$first_print($mode == 2 ? $text{'save_ssl8'}
				 : $text{'save_ssl9'});
	if (!$virt) {
		&$second_print($text{'delete_noapache'});
		goto VIRTFAILED;
		}
	local $lref = &read_file_lines($virt->{'file'});
	local $nonlref = &read_file_lines($nonvirt->{'file'});
	local $tmpl = &get_template($_[0]->{'tmpl'});
	local @dirs = @$nonlref[$nonvirt->{'line'}+1 .. $nonvirt->{'eline'}-1];
	push(@dirs, &apache_ssl_directives($_[0], $tmpl));
	splice(@$lref, $virt->{'line'} + 1,
	       $virt->{'eline'} - $virt->{'line'} - 1, @dirs);
	&flush_file_lines($virt->{'file'});
	$rv++;
	undef(@apache::get_config_cache);
	($virt, $vconf, $conf) = &get_apache_virtual($_[1]->{'dom'},
					      	     $_[1]->{'web_sslport'});
	&$second_print($text{'setup_done'});
	}
if ($_[0]->{'user'} ne $_[1]->{'user'}) {
	# Username has changed .. copy suexec directives from parent
	&$first_print($text{'save_ssl10'});
	if (!$virt || !$nonvirt) {
		&$second_print($text{'delete_noapache'});
		goto VIRTFAILED;
		}
	foreach my $dir ("User", "Group", "SuexecUserGroup") {
		local @vals = &apache::find_directive($dir, $nonvconf);
		&apache::save_directive($dir, \@vals, $vconf, $conf);
		}
	&flush_file_lines($virt->{'file'});
	$rv++;
	&$second_print($text{'setup_done'});
	}
if ($_[0]->{'dom'} ne $_[1]->{'dom'}) {
        # Domain name has changed .. fix up Apache config by copying relevant
        # directives from the real domain
        &$first_print($text{'save_ssl2'});
	if (!$virt || !$nonvirt) {
		&$second_print($text{'delete_noapache'});
		goto VIRTFAILED;
		}
	foreach my $dir ("ServerName", "ServerAlias",
			 "ErrorLog", "TransferLog", "CustomLog",
			 "RewriteCond", "RewriteRule") {
		local @vals = &apache::find_directive($dir, $nonvconf);
		&apache::save_directive($dir, \@vals, $vconf, $conf);
		}
        &flush_file_lines($virt->{'file'});
        $rv++;
        &$second_print($text{'setup_done'});
        }

# Code after here still works even if SSL virtualhost is missing
VIRTFAILED:
if ($_[0]->{'ip'} ne $_[1]->{'ip'} && $_[1]->{'ssl_same'}) {
	# IP has changed - maybe clear ssl_same field
	local ($sslclash) = grep { $_->{'ip'} eq $_[0]->{'ip'} &&
				   $_->{'ssl'} &&
				   $_->{'id'} ne $_[0]->{'id'} &&
				   !$_->{'ssl_same'} } &list_domains();
	local $oldsslclash = &get_domain($_[1]->{'ssl_same'});
	if ($sslclash && $_[1]->{'ssl_same'} eq $sslclash->{'id'}) {
		# No need to change
		}
	elsif ($sslclash &&
	       &check_domain_certificate($_[0]->{'dom'}, $sslclash)) {
		# New domain with same cert
		$_[0]->{'ssl_cert'} = $sslclash->{'ssl_cert'};
		$_[0]->{'ssl_key'} = $sslclash->{'ssl_key'};
		$_[0]->{'ssl_same'} = $sslclash->{'id'};
		$chained = &get_chained_certificate_file($sslclash);
		$_[0]->{'ssl_chain'} = $chained;
		}
	else {
		# No domain has the same cert anymore - copy the one from the
		# old sslclash domain
		$_[0]->{'ssl_cert'} = &default_certificate_file($_[0], 'cert');
		$_[0]->{'ssl_key'} = &default_certificate_file($_[0], 'key');
		&copy_source_dest_as_domain_user($_[0],
			$oldsslclash->{'ssl_cert'}, $_[0]->{'ssl_cert'});
		&copy_source_dest_as_domain_user($_[0],
			$oldsslclash->{'ssl_key'}, $_[0]->{'ssl_key'});
		delete($_[0]->{'ssl_same'});
		}
	}
if ($_[0]->{'home'} ne $_[1]->{'home'}) {
	# Fix SSL cert file locations
	foreach my $k ('ssl_cert', 'ssl_key', 'ssl_chain') {
		$_[0]->{$k} =~ s/\Q$_[1]->{'home'}\E\//$_[0]->{'home'}\//;
		}
	}
if ($_[0]->{'dom'} ne $_[1]->{'dom'} && &self_signed_cert($_[0]) &&
    !&check_domain_certificate($_[0]->{'dom'}, $_[0])) {
	# Domain name has changed .. re-generate self-signed cert
	&$first_print($text{'save_ssl11'});
	local $info = &cert_info($_[0]);
	&lock_file($_[0]->{'ssl_cert'});
	&lock_file($_[0]->{'ssl_key'});
	local $err = &generate_self_signed_cert(
		$_[0]->{'ssl_cert'}, $_[0]->{'ssl_key'},
		undef,
		1825,
		$info->{'c'},
		$info->{'st'},
		$info->{'l'},
		$info->{'o'},
		$info->{'ou'},
		"*.$_[0]->{'dom'}",
		$_[0]->{'emailto'},
		$info->{'alt'},
		$_[0],
		);
	&unlock_file($_[0]->{'ssl_key'});
	&unlock_file($_[0]->{'ssl_cert'});
	if ($err) {
		&$second_print(&text('setup_eopenssl', $err));
		}
	else {
		$rv++;
		&$second_print($text{'setup_done'});
		}
	}

# Changes for Webmin and Usermin
if ($_[0]->{'ip'} ne $_[1]->{'ip'} ||
    $_[0]->{'home'} ne $_[1]->{'home'}) {
        # IP address has changed .. fix per-IP SSL cert
	&modify_ipkeys($_[0], $_[1], \&get_miniserv_config,
		       \&put_miniserv_config,
		       \&restart_webmin);
	if (&foreign_installed("usermin")) {
		&foreign_require("usermin", "usermin-lib.pl");
		&modify_ipkeys($_[0], $_[1],
			       \&usermin::get_usermin_miniserv_config,
			       \&usermin::put_usermin_miniserv_config,
			       \&restart_usermin);
		}
	}
&release_lock_web($_[0]);
&register_post_action(\&restart_apache, 1) if ($rv);
return $rv;
}

# delete_ssl(&domain)
# Deletes the SSL virtual server from the Apache config
sub delete_ssl
{
&require_apache();
&$first_print($text{'delete_ssl'});
&obtain_lock_web($_[0]);
local $conf = &apache::get_config();

# Remove the custom Listen directive added for the domain, if any
&remove_listen($d, $conf, $d->{'web_sslport'} || $default_web_sslport);

# Remove the <virtualhost>
local ($virt, $vconf) = &get_apache_virtual($_[0]->{'dom'},
			    $_[0]->{'web_sslport'} || $default_web_sslport);
local $tmpl = &get_template($_[0]->{'template'});
if ($virt) {
	&delete_web_virtual_server($virt);
	&$second_print($text{'setup_done'});
	&register_post_action(\&restart_apache, 1);
	}
else {
	&$second_print($text{'delete_noapache'});
	}
undef(@apache::get_config_cache);

# Delete per-IP SSL cert
&delete_ipkeys($_[0], \&get_miniserv_config,
	       \&put_miniserv_config,
	       \&restart_webmin);
if (&foreign_installed("usermin")) {
	&foreign_require("usermin", "usermin-lib.pl");
	&delete_ipkeys($_[0], \&usermin::get_usermin_miniserv_config,
		      \&usermin::put_usermin_miniserv_config,
		      \&restart_usermin);
	}

# If any other domains were using this one's SSL cert or key, break the linkage
foreach my $od (&get_domain_by("ssl_same", $_[0]->{'id'})) {
	foreach my $k ('cert', 'key', 'ca') {
		if ($od->{'ssl_'.$k}) {
			$od->{'ssl_'.$k} = &default_certificate_file($od, $k);
			&copy_source_dest($d->{'ssl_'.$k}, $od->{'ssl_'.$k});
			}
		}
	local ($ovirt, $ovconf, $conf) = &get_apache_virtual(
		$od->{'dom'}, $od->{'web_sslport'});
	if ($ovirt) {
		&apache::save_directive("SSLCertificateFile",
			[ $od->{'ssl_cert'} ], $ovconf, $conf);
		&apache::save_directive("SSLCertificateKeyFile",
			$od->{'ssl_key'} ? [ $od->{'ssl_key'} ] : [ ],
			$ovconf, $conf);
		&apache::save_directive("SSLCACertificateFile",
			$od->{'ssl_chain'} ? [ $od->{'ssl_chain'} ] : [ ],
			$ovconf, $conf);
		&flush_file_lines($ovirt->{'file'});
		}
	delete($od->{'ssl_same'});
	&save_domain($od);
	}

# If this domain was sharing a cert with another, forget about it now
if ($_[0]->{'ssl_same'}) {
	delete($_[0]->{'ssl_cert'});
	delete($_[0]->{'ssl_key'});
	delete($_[0]->{'ssl_chain'});
	delete($_[0]->{'ssl_same'});
	}

&release_lock_web($_[0]);
}

# clone_ssl(&domain, &old-domain)
# Since the non-SSL website has already been cloned and modified, just copy
# its directives and add SSL-specific options.
sub clone_ssl
{
local ($d, $oldd) = @_;
local $tmpl = &get_template($d->{'template'});
&$first_print($text{'clone_ssl'});
local ($virt, $vconf) = &get_apache_virtual($d->{'dom'}, $d->{'web_port'});
local ($svirt, $svconf) = &get_apache_virtual($d->{'dom'}, $d->{'web_sslport'});
if (!$virt) {
	&$second_print($text{'setup_esslcopy'});
	return 0;
	}
if (!$svirt) {
	&$second_print($text{'clone_webnew'});
	return 0;
	}

# Copy across directives, adding the ones for SSL
&obtain_lock_web($d);
local $lref = &read_file_lines($virt->{'file'});
local @ssldirs = &apache_ssl_directives($d, $tmpl);
local $slref = &read_file_lines($svirt->{'file'});
splice(@$slref, $svirt->{'line'}+1, $svirt->{'eline'}-$svirt->{'line'}-1,
       @ssldirs, @$lref[$virt->{'line'}+1 .. $virt->{'eline'}-1]);
&flush_file_lines($svirt->{'file'});
undef(@apache::get_config_cache);
&release_lock_web($d);

&$second_print($text{'setup_done'});
&register_post_action(\&restart_apache, 1);
return 1;
}

# validate_ssl(&domain)
# Returns an error message if no SSL Apache virtual host exists, or if the
# cert files are missing.
sub validate_ssl
{
local ($d) = @_;
local ($virt, $vconf) = &get_apache_virtual($d->{'dom'},
					    $d->{'web_sslport'});
return &text('validate_essl', "<tt>$d->{'dom'}</tt>") if (!$virt);

# Check IP addresses
if ($d->{'virt'}) {
	local $ipp = $d->{'ip'}.":".$d->{'web_sslport'};
	&indexof($ipp, @{$virt->{'words'}}) >= 0 ||
		return &text('validate_ewebip', $ipp);
	}
if ($d->{'virt6'}) {
	local $ipp = "[".$d->{'ip6'}."]:".$d->{'web_sslport'};
	&indexof($ipp, @{$virt->{'words'}}) >= 0 ||
		return &text('validate_ewebip6', $ipp);
	}

# Make sure cert file exists
local $cert = &apache::find_directive("SSLCertificateFile", $vconf, 1);
if (!$cert) {
	return &text('validate_esslcert');
	}
elsif (!-r $cert) {
	return &text('validate_esslcertfile', "<tt>$cert</tt>");
	}

# Make sure key exists
local $key = &apache::find_directive("SSLCertificateKeyFile", $vconf, 1);
if ($key && !-r $key) {
	return &text('validate_esslkeyfile', "<tt>$key</tt>");
	}

# Make sure this domain or www.domain matches cert
if (!&check_domain_certificate($d->{'dom'}, $d) &&
    !&check_domain_certificate("www.".$d->{'dom'}, $d)) {
	return &text('validate_essldom',
		     "<tt>".$d->{'dom'}."</tt>",
		     "<tt>"."www.".$d->{'dom'}."</tt>",
		     join(", ", map { "<tt>$_</tt>" }
			            &list_domain_certificate($d)));
	}

# Make sure the first virtualhost on this IP serves the same cert
&require_apache();
local $conf = &apache::get_config();
local $firstcert;
foreach my $v (&apache::find_directive_struct("VirtualHost",
					      $conf)) {
	local ($vip, $vport) = split(/:/, $v->{'words'}->[0]);
	if ($vip eq $d->{'ip'} && $vport == $d->{'web_sslport'}) {
		# Found first one .. is it's cert OK?
		$firstcert = &apache::find_directive("SSLCertificateFile",
			$v->{'members'}, 1);
		last;
		}
	}
if ($firstcert) {
	local $info = &cert_file_info($firstcert, $d);
	if (!&check_domain_certificate($d->{'dom'}, $info) &&
	    !&check_domain_certificate("www.".$d->{'dom'}, $info)) {
		return &text('validate_esslfirst',
			     "<tt>".$d->{'dom'}."</tt>",
			     "<tt>"."www.".$d->{'dom'}."</tt>",
			     join(", ", map { "<tt>$_</tt>" }
					    &list_domain_certificate($info)),
			     $d->{'ip'});
		}
	}

return undef;
}

# check_ssl_clash(&domain, [field])
# Returns 1 if an SSL Apache webserver already exists for some domain, or if
# port 443 on the domain's IP is in use by Webmin or Usermin
sub check_ssl_clash
{
local $tmpl = &get_template($_[0]->{'template'});
local $web_sslport = $tmpl->{'web_sslport'} || 443;
if (!$_[1] || $_[1] eq 'dom') {
	# Check for <virtualhost> clash by domain name
	local ($cvirt, $cconf) = &get_apache_virtual($_[0]->{'dom'},
						     $web_sslport);
	return 1 if ($cvirt);
	}
if (!$_[1] || $_[1] eq 'ip') {
	# Check for clash by IP and port with Webmin or Usermin
	local $err = &check_webmin_port_clash($_[0], $web_sslport);
	return $err if ($err);
	}
return 0;
}

# check_webmin_port_clash(&domain, port)
# Returns 1 if Webmin or Usermin is using some IP and port
sub check_webmin_port_clash
{
my ($d, $port) = @_;
foreign_require("webmin", "webmin-lib.pl");
my @checks;
my %miniserv;
&get_miniserv_config(\%miniserv);
push(@checks, [ \%miniserv, "Webmin" ]);
if (&foreign_installed("usermin")) {
	my %uminiserv;
	foreign_require("usermin", "usermin-lib.pl");
	&usermin::get_usermin_miniserv_config(\%uminiserv);
	push(@checks, [ \%uminiserv, "Usermin" ]);
	}
foreach my $c (@checks) {
	my @sockets = &webmin::get_miniserv_sockets($c->[0]);
	foreach my $s (@sockets) {
		if (($s->[0] eq '*' || $s->[0] eq $d->{'ip'}) &&
		    $s->[1] == $port) {
			return &text('setup_esslportclash',
				     $d->{'ip'}, $port, $c->[1]);
			}
		}
	}
return undef;
}

# disable_ssl(&domain)
# Adds a directive to force all requests to show an error page
sub disable_ssl
{
&$first_print($text{'disable_ssl'});
&require_apache();
local ($virt, $vconf) = &get_apache_virtual($_[0]->{'dom'},
					    $_[0]->{'web_sslport'});
if ($virt) {
        &create_disable_directives($virt, $vconf, $_[0]);
        &$second_print($text{'setup_done'});
	&register_post_action(\&restart_apache);
        }
else {
        &$second_print($text{'delete_noapache'});
        }
}

# enable_ssl(&domain)
sub enable_ssl
{
&$first_print($text{'enable_ssl'});
&require_apache();
local ($virt, $vconf) = &get_apache_virtual($_[0]->{'dom'},
					    $_[0]->{'web_sslport'});
if ($virt) {
        &remove_disable_directives($virt, $vconf, $_[0]);
        &$second_print($text{'setup_done'});
	&register_post_action(\&restart_apache);
        }
else {
        &$second_print($text{'delete_noapache'});
        }
}

# backup_ssl(&domain, file)
# Save the SSL virtual server's Apache config as a separate file
sub backup_ssl
{
&$first_print($text{'backup_sslcp'});

# Save the apache directives
local ($virt, $vconf) = &get_apache_virtual($_[0]->{'dom'},
					    $_[0]->{'web_sslport'});
if ($virt) {
	local $lref = &read_file_lines($virt->{'file'});
	local $l;
	&open_tempfile(FILE, ">$_[1]");
	foreach $l (@$lref[$virt->{'line'} .. $virt->{'eline'}]) {
		&print_tempfile(FILE, "$l\n");
		}
	&close_tempfile(FILE);

	# Save the cert and key, if any
	local $cert = &apache::find_directive("SSLCertificateFile", $vconf, 1);
	if ($cert) {
		&copy_source_dest($cert, "$_[1]_cert");
		}
	local $key = &apache::find_directive("SSLCertificateKeyFile", $vconf,1);
	if ($key && $key ne $cert) {
		&copy_source_dest($key, "$_[1]_key");
		}

	&$second_print($text{'setup_done'});
	return 1;
	}
else {
	&$second_print($text{'delete_noapache'});
	return 0;
	}
}

# restore_ssl(&domain, file, &options)
# Update the SSL virtual server's Apache configuration from a file. Does not
# change the actual <Virtualhost> lines!
sub restore_ssl
{
&$first_print($text{'restore_sslcp'});
&obtain_lock_web($_[0]);
my $rv = 1;

# Restore the Apache directives
local ($virt, $vconf) = &get_apache_virtual($_[0]->{'dom'},
					    $_[0]->{'web_sslport'});
if ($virt) {
	local $srclref = &read_file_lines($_[1], 1);
	local $dstlref = &read_file_lines($virt->{'file'});
	splice(@$dstlref, $virt->{'line'}+1,
	       $virt->{'eline'}-$virt->{'line'}-1,
	       @$srclref[1 .. @$srclref-2]);

	# Fix ip address in <Virtualhost> section (if needed)
	if ($dstlref->[$virt->{'line'}] =~
	    /^(.*<Virtualhost\s+)([0-9\.]+)(.*)$/i) {
		$dstlref->[$virt->{'line'}] = $1.$_[0]->{'ip'}.$3;
		}
	if ($_[5]->{'home'} && $_[5]->{'home'} ne $_[0]->{'home'}) {
		# Fix up any DocumentRoot or other file-related directives
		local $i;
		foreach $i ($virt->{'line'} ..
			    $virt->{'line'}+scalar(@$srclref)-1) {
			$dstlref->[$i] =~
			    s/\Q$_[5]->{'home'}\E/$_[0]->{'home'}/g;
			}
		}
	&flush_file_lines($virt->{'file'});
	undef(@apache::get_config_cache);

	# Copy suexec-related directives from non-SSL virtual host
	($virt, $vconf) = &get_apache_virtual($_[0]->{'dom'},
					      $_[0]->{'web_sslport'});
	local ($nvirt, $nvconf) = &get_apache_virtual($_[0]->{'dom'},
						      $_[0]->{'web_port'});
	if ($nvirt && $virt) {
		local $any;
		foreach my $dir ("User", "Group", "SuexecUserGroup") {
			local @vals = &apache::find_directive($dir, $nvconf);
			&apache::save_directive($dir, \@vals, $vconf, $conf);
			$any++ if (@vals);
			}
		if ($any) {
			&flush_file_lines($virt->{'file'});
			}
		}

	# Restore the cert and key, if any and if saved
	local $cert = &apache::find_directive("SSLCertificateFile", $vconf, 1);
	if ($cert && -r "$_[1]_cert") {
		&lock_file($cert);
		&set_ownership_permissions(
			$_[0]->{'uid'}, undef, undef, "$_[1]_cert");
		&copy_source_dest_as_domain_user($_[0], "$_[1]_cert", $cert);
		&unlock_file($cert);
		}
	local $key = &apache::find_directive("SSLCertificateKeyFile", $vconf,1);
	if ($key && -r "$_[1]_key" && $key ne $cert) {
		&lock_file($key);
		&set_ownership_permissions(
			$_[0]->{'uid'}, undef, undef, "$_[1]_key");
		&copy_source_dest_as_domain_user($_[0], "$_[1]_key", $key);
		&unlock_file($key);
		}

	# Re-setup any SSL passphrase
	&save_domain_passphrase($_[0]);

	&$second_print($text{'setup_done'});
	}
else {
	&$second_print($text{'delete_noapache'});
	$rv = 0;
	}

&release_lock_web($_[0]);
&register_post_action(\&restart_apache);
return $rv;
}

# cert_info(&domain)
# Returns a hash of details of a domain's cert
sub cert_info
{
return &cert_file_info($_[0]->{'ssl_cert'}, $_[0]);
}

# cert_file_info(file, &domain)
# Returns a hash of details of a cert in some file
sub cert_file_info
{
local ($file, $d) = @_;
local %rv;
local $_;
local $cmd = "openssl x509 -in ".quotemeta($file)." -issuer -subject -enddate -text";
if (&is_under_directory($d->{'home'}, $file)) {
	open(OUT, &command_as_user($d->{'user'}, 0, $cmd)." |");
	}
else {
	open(OUT, $cmd." |");
	}
while(<OUT>) {
	s/\r|\n//g;
	s/http:\/\//http:\|\|/g;	# So we can parse with regexp
	if (/subject=.*C=([^\/]+)/) {
		$rv{'c'} = $1;
		}
	if (/subject=.*ST=([^\/]+)/) {
		$rv{'st'} = $1;
		}
	if (/subject=.*L=([^\/]+)/) {
		$rv{'l'} = $1;
		}
	if (/subject=.*O=([^\/]+)/) {
		$rv{'o'} = $1;
		}
	if (/subject=.*OU=([^\/]+)/) {
		$rv{'ou'} = $1;
		}
	if (/subject=.*CN=([^\/]+)/) {
		$rv{'cn'} = $1;
		}
	if (/subject=.*emailAddress=([^\/]+)/) {
		$rv{'email'} = $1;
		}

	if (/issuer=.*C=([^\/]+)/) {
		$rv{'issuer_c'} = $1;
		}
	if (/issuer=.*ST=([^\/]+)/) {
		$rv{'issuer_st'} = $1;
		}
	if (/issuer=.*L=([^\/]+)/) {
		$rv{'issuer_l'} = $1;
		}
	if (/issuer=.*O=([^\/]+)/) {
		$rv{'issuer_o'} = $1;
		}
	if (/issuer=.*OU=([^\/]+)/) {
		$rv{'issuer_ou'} = $1;
		}
	if (/issuer=.*CN=([^\/]+)/) {
		$rv{'issuer_cn'} = $1;
		}
	if (/issuer=.*emailAddress=([^\/]+)/) {
		$rv{'issuer_email'} = $1;
		}
	if (/notAfter=(.*)/) {
		$rv{'notafter'} = $1;
		}
	if (/Subject\s+Alternative\s+Name/i) {
		local $alts = <OUT>;
		$alts =~ s/^\s+//;
		foreach my $a (split(/[, ]+/, $alts)) {
			if ($a =~ /^DNS:(\S+)/) {
				push(@{$rv{'alt'}}, $1);
				}
			}
		}
	}
close(OUT);
foreach my $k (keys %rv) {
	$rv{$k} =~ s/http:\|\|/http:\/\//g;
	}
$rv{'type'} = $rv{'o'} eq $rv{'issuer_o'} ? $text{'cert_typeself'}
					  : $text{'cert_typereal'};
return \%rv;
}

# check_passphrase(key-data, passphrase)
# Returns 0 if a passphrase is needed by not given, 1 if not needed, 2 if OK
sub check_passphrase
{
local ($newkey, $pass) = @_;
local $temp = &transname();
&open_tempfile(KEY, ">$temp", 0, 1);
&set_ownership_permissions(undef, undef, 0700, $temp);
&print_tempfile(KEY, $newkey);
&close_tempfile(KEY);
local $rv = &execute_command("openssl rsa -in ".quotemeta($temp).
			     " -text -passin pass:NONE");
if (!$rv) {
	return 1;
	}
if ($pass) {
	local $rv = &execute_command("openssl rsa -in ".quotemeta($temp).
				     " -text -passin pass:".quotemeta($pass));
	if (!$rv) {
		return 2;
		}
	}
return 0;
}

# save_domain_passphrase(&domain)
# Configure Apache to use the right passphrase for a domain, if one is needed.
# Otherwise, remove the passphrase config.
sub save_domain_passphrase
{
local ($d) = @_;
local $pass_script = "$ssl_passphrase_dir/$d->{'id'}";
&lock_file($pass_script);
local @pps = &apache::find_directive("SSLPassPhraseDialog", $conf);
local @pps_str = &apache::find_directive_struct("SSLPassPhraseDialog", $conf);
&lock_file(@pps_str ? $pps_str[0]->{'file'} : $conf->[0]->{'file'});
local ($pps) = grep { $_ eq "exec:$pass_script" } @pps;
if ($d->{'ssl_pass'}) {
	# Create script, add to Apache config
	if (!-d $ssl_passphrase_dir) {
		&make_dir($ssl_passphrase_dir, 0700);
		}
	&open_tempfile(SCRIPT, ">$pass_script");
	&print_tempfile(SCRIPT, "#!/bin/sh\n");
	&print_tempfile(SCRIPT, "echo ".quotemeta($d->{'ssl_pass'})."\n");
	&close_tempfile(SCRIPT);
	&set_ownership_permissions(undef, undef, 0700, $pass_script);
	push(@pps, "exec:$pass_script");
	}
else {
	# Remove script and from Apache config
	if ($pps) {
		@pps = grep { $_ ne $pps } @pps;
		}
	&unlink_file($pass_script);
	}
&lock_file(@pps_str ? $pps_str[0]->{'file'} : $conf->[0]->{'file'});
&apache::save_directive("SSLPassPhraseDialog", \@pps, $conf, $conf);
&flush_file_lines();
&register_post_action(\&restart_apache, 1);
}

# check_cert_key_match(cert-text, key-text)
# Checks if the modulus for a cert and key match and are valid. Returns undef 
# on success or an error message on failure.
sub check_cert_key_match
{
local ($certtext, $keytext) = @_;
local $certfile = &transname();
local $keyfile = &transname();
foreach $tf ([ $certtext, $certfile ], [ $keytext, $keyfile ]) {
	&open_tempfile(CERTOUT, ">$tf->[1]", 0, 1);
	&print_tempfile(CERTOUT, $tf->[0]);
	&close_tempfile(CERTOUT);
	}
# Get certificate modulus
local $certmodout = &backquote_command(
	"openssl x509 -noout -modulus -in $certfile 2>&1");
$certmodout =~ /Modulus=([A-F0-9]+)/i ||
	return "Certificate data is not valid : $certmodout";
local $certmod = $1;

# Get key modulus
local $keymodout = &backquote_command(
	"openssl rsa -noout -modulus -in $keyfile 2>&1");
$keymodout =~ /Modulus=([A-F0-9]+)/i ||
	return "Key data is not valid : $keymodout";
local $keymod = $1;

# Make sure they match
$certmod eq $keymod ||
	return "Certificate and private key do not match";

return undef;
}

# validate_cert_format(data|file, type)
# Checks if some file or string contains valid cert or key data, and returns
# an error message if not. The type can be one of 'key', 'cert', 'ca' or 'csr'
sub validate_cert_format
{
local ($data, $type) = @_;
if ($data =~ /^\//) {
	$data = &read_file_contents($data);
	}
local %headers = ( 'key' => '(RSA )?PRIVATE KEY',
		   'cert' => 'CERTIFICATE',
		   'ca' => 'CERTIFICATE',
		   'csr' => 'CERTIFICATE REQUEST',
		   'newkey' => '(RSA ?)PRIVATE KEY' );
local $h = $headers{$type};
$h || return "Unknown SSL file type $type";
local @lines = grep { /\S/ } split(/\r?\n/, $data);
local $begin = quotemeta("-----BEGIN ").$h.quotemeta("-----");
local $end = quotemeta("-----END ").$h.quotemeta("-----");
$lines[0] =~ /^$begin$/ || return "Data does not start with line $begin";
$lines[$#lines] =~ /^$end$/ || return "Data does not end with line $begin";
for(my $i=1; $i<$#lines; $i++) {
	$lines[$i] =~ /^[A-Za-z0-9\+\/=]+$/ ||
		return "Line ".($i+1)." does not look like PEM format";
	}
@lines > 4 || return "Data only has ".scalar(@lines)." lines";
return undef;
}

# cert_pem_data(&domain)
# Returns a domain's cert in PEM format
sub cert_pem_data
{
local ($d) = @_;
local $data = &read_file_contents_as_domain_user($d, $d->{'ssl_cert'});
if ($data =~ /(-----BEGIN\s+CERTIFICATE-----\n([A-Za-z0-9\+\/=\n\r]+)-----END\s+CERTIFICATE-----)/) {
	return $1;
	}
return undef;
}

# key_pem_data(&domain)
# Returns a domain's key in PEM format
sub key_pem_data
{
local ($d) = @_;
local $data = &read_file_contents_as_domain_user($d, $d->{'ssl_key'} ||
						     $d->{'ssl_cert'});
if ($data =~ /(-----BEGIN\s+RSA\s+PRIVATE\s+KEY-----\n([A-Za-z0-9\+\/=\n\r]+)-----END\s+RSA\s+PRIVATE\s+KEY-----)/) {
	return $1;
	}
elsif ($data =~ /(-----BEGIN\s+PRIVATE\s+KEY-----\n([A-Za-z0-9\+\/=\n\r]+)-----END\s+PRIVATE\s+KEY-----)/) {
	return $1;
	}
return undef;
}

# cert_pkcs12_data(&domain)
# Returns a domain's cert in PKCS12 format
sub cert_pkcs12_data
{
local ($d) = @_;
local $cmd = "openssl pkcs12 -in ".quotemeta($d->{'ssl_cert'}).
             " -inkey ".quotemeta($_[0]->{'ssl_key'}).
	     " -export -passout pass: -nokeys";
open(OUT, &command_as_user($d->{'user'}, 0, $cmd)." |");
while(<OUT>) {
	$data .= $_;
	}
close(OUT);
return $data;
}

# key_pkcs12_data(&domain)
# Returns a domain's key in PKCS12 format
sub key_pkcs12_data
{
local ($d) = @_;
local $cmd = "openssl pkcs12 -in ".quotemeta($d->{'ssl_cert'}).
             " -inkey ".quotemeta($_[0]->{'ssl_key'}).
	     " -export -passout pass: -nocerts";
open(OUT, &command_as_user($d->{'user'}, 0, $cmd)." |");
while(<OUT>) {
	$data .= $_;
	}
close(OUT);
return $data;
}

# setup_ipkeys(&domain, &miniserv-getter, &miniserv-saver, &post-action)
# Add the per-IP SSL key for some domain, based on its IP address
sub setup_ipkeys
{
local ($dom, $getfunc, $putfunc, $postfunc) = @_;
&foreign_require("webmin", "webmin-lib.pl");
local %miniserv;
&$getfunc(\%miniserv);
local @ipkeys = &webmin::get_ipkeys(\%miniserv);
push(@ipkeys, { 'ips' => [ $_[0]->{'ip'} ],
		'key' => $_[0]->{'ssl_key'},
		'cert' => $_[0]->{'ssl_cert'} });
&webmin::save_ipkeys(\%miniserv, \@ipkeys);
&$putfunc(\%miniserv);
&register_post_action($postfunc);
return 1;
}

# delete_ipkeys(&domain, &miniserv-getter, &miniserv-saver, &post-action)
# Remove the per-IP SSL key for some domain, based on its IP address
sub delete_ipkeys
{
local ($dom, $getfunc, $putfunc, $postfunc) = @_;
&foreign_require("webmin", "webmin-lib.pl");
local %miniserv;
&$getfunc(\%miniserv);
local @ipkeys = &webmin::get_ipkeys(\%miniserv);
local @newipkeys = grep { $_->{'ips'}->[0] ne $_[0]->{'ip'} } @ipkeys;
if (@ipkeys != @newipkeys) {
	&webmin::save_ipkeys(\%miniserv, \@newipkeys);
	&$putfunc(\%miniserv);
	&register_post_action($postfunc);
	return 1;
	}
return 0;
}

# modify_ipkeys(&domain, &olddomain, &miniserv-getter, &miniserv-saver,
# 		&post-action)
# Remove and then re-add the per-IP SSL key for a domain, to pick up any
# IP or home directory change
sub modify_ipkeys
{
local ($dom, $olddom, $getfunc, $putfunc, $postfunc) = @_;
if (&delete_ipkeys($olddom, $getfunc, $putfunc, $postfunc)) {
	&setup_ipkeys($dom, $getfunc, $putfunc, $postfunc);
	}
}

# apache_ssl_directives(&domain, template)
# Returns extra Apache directives needed for SSL
sub apache_ssl_directives
{
local ($d, $tmpl) = @_;
local @dirs;
push(@dirs, "SSLEngine on");
push(@dirs, "SSLCertificateFile $d->{'ssl_cert'}");
push(@dirs, "SSLCertificateKeyFile $d->{'ssl_key'}");
if ($d->{'ssl_chain'}) {
	push(@dirs, "SSLCACertificateFile $d->{'ssl_chain'}");
	}
return @dirs;
}

# get_chained_certificate_file(&domain)
# Returns the file used for the chained cert, or undef if not set
sub get_chained_certificate_file
{
local ($d) = @_;
local ($virt, $vconf) = &get_apache_virtual($d->{'dom'},
					    $d->{'web_sslport'});
return undef if (!$virt);
local ($cert) = &apache::find_directive("SSLCACertificateFile", $vconf);
return $cert;
}

# save_chained_certificate_file(&domain, [file])
# Updates the chained cert file, or removed it if file is undef
sub save_chained_certificate_file
{
local ($d, $file) = @_;
local ($virt, $vconf) = &get_apache_virtual($d->{'dom'},
					    $d->{'web_sslport'});
return undef if (!$virt);
&lock_file($virt->{'file'});
&apache::save_directive("SSLCACertificateFile", $file ? [ $file ] : [ ],
			$vconf,$conf);
&flush_file_lines($virt->{'file'});
&unlock_file($virt->{'file'});
&register_post_action(\&restart_apache);
}

# check_certificate_data(data)
# Checks if some data looks like a valid cert. Returns undef if OK, or an error
# message if not
sub check_certificate_data
{
local ($data) = @_;
local $temp = &transname();
&open_tempfile(CERTDATA, ">$temp", 0, 1);
&print_tempfile(CERTDATA, $data);
&close_tempfile(CERTDATA);
local $out = &backquote_command("openssl x509 -in ".quotemeta($temp)." -issuer -subject -enddate 2>&1");
local $ex = $?;
&unlink_file($temp);
if ($ex) {
	return "<tt>".&html_escape($out)."</tt>";
	}
elsif ($out !~ /subject=.*(CN|O)=/) {
	return $text{'cert_esubject'};
	}
else {
	return undef;
	}
}

# default_certificate_file(&domain, "cert"|"key"|"ca")
# Returns the default path that should be used for a cert, key or CA file
sub default_certificate_file
{
local ($d, $mode) = @_;
return $config{$mode.'_tmpl'} ?
	    &absolute_domain_path($d,
	     &substitute_domain_template($config{$mode.'_tmpl'}, $d)) :
	    "$d->{'home'}/ssl.".$mode;
}

# set_certificate_permissions(&domain, file)
# Set permissions on a cert file so that Apache can read them.
sub set_certificate_permissions
{
local ($d, $file) = @_;
&set_permissions_as_domain_user($d, 0700, $file);
}

# check_domain_certificate(domain-name, &domain-with-cert|&cert-info)
# Returns 1 if some virtual server's certificate can be used for a particular
# domain, 0 if not. Based on the common names, including wildcards and UCC
sub check_domain_certificate
{
local ($dname, $d_or_info) = @_;
local $info = $d_or_info->{'dom'} ? &cert_info($d_or_info) : $d_or_info;
if (lc($info->{'cn'}) eq lc($dname)) {
	# Exact match
	return 1;
	}
elsif ($info->{'cn'} =~ /^\*\.(\S+)$/ &&
       (lc($dname) eq lc($1) || $dname =~ /\.\Q$1\E$/i)) {
	# Matches wildcard
	return 1;
	}
else {
	# Check for subjectAltNames match (as seen in UCC certs)
	foreach my $a (@{$info->{'alt'}}) {
		if (lc($a) eq $dname ||
		    $a =~ /^\*\.(\S+)$/ &&
		    (lc($dname) eq lc($1) || $dname =~ /\.\Q$1\E$/i)) {
			return 1;
			}
		}
	return 0;
	}
}

# list_domain_certificate(&domain|&cert-info)
# Returns a list of domain names that are in the cert for a domain
sub list_domain_certificate
{
local ($d_or_info) = @_;
local $info = $d_or_info->{'dom'} ? &cert_info($d_or_info) : $d_or_info;
local @rv;
push(@rv, $info->{'cn'});
push(@rv, @{$info->{'alt'}});
return &unique(@rv);
}

# self_signed_cert(&domain)
# Returns 1 if some domain has a self-signed certificate
sub self_signed_cert
{
local ($d) = @_;
local $info = &cert_info($d);
return $info->{'issuer_cn'} eq $info->{'cn'} &&
       $info->{'issuer_o'} eq $info->{'o'};
}

# find_openssl_config_file()
# Returns the full path to the OpenSSL config file, or undef if not found
sub find_openssl_config_file
{
foreach my $p ($config{'openssl_cnf'},		# Module config
	       "/etc/ssl/openssl.cnf",		# Debian and FreeBSD
	       "/etc/openssl.cnf",
               "/usr/local/etc/openssl.cnf",
	       "/etc/pki/tls/openssl.cnf",	# Redhat
	       "/opt/csw/ssl/openssl.cnf",	# Solaris CSW
	       "/opt/csw/etc/ssl/openssl.cnf",	# Solaris CSW
	       "/System/Library/OpenSSL/openssl.cnf", # OSX
	      ) {
	return $p if ($p && -r $p);
	}
return undef;
}

# generate_self_signed_cert(certfile, keyfile, size, days, country, state,
# 			    city, org, orgunit, commonname, email, &altnames,
# 			    &domain)
# Generates a new self-signed cert, and stores it in the given cert and key
# files. Returns undef on success, or an error message on failure.
sub generate_self_signed_cert
{
local ($certfile, $keyfile, $size, $days, $country, $state, $city, $org,
       $orgunit, $common, $email, $altnames, $d) = @_;
&foreign_require("webmin", "webmin-lib.pl");
$size ||= $config{'key_size'} || $webmin::default_key_size;
$days ||= 1825;

# Prepare for SSL alt names
local $flag;
if ($altnames && @$altnames) {
	$flag = &setup_openssl_altnames([ @$altnames, $common ], 1);
	}

# Call openssl and write to temp files
local $outtemp = &transname();
local $keytemp = &transname();
local $certtemp = &transname();
&open_execute_command(CA, "openssl req $flag -newkey rsa:$size -x509 -nodes -out $certtemp -keyout $keytemp -days $days >$outtemp 2>&1", 0);
print CA ($country || "."),"\n";
print CA ($state || "."),"\n";
print CA ($city || "."),"\n";
print CA ($org || "."),"\n";
print CA ($orgunit || "."),"\n";
print CA ($common || "*"),"\n";
print CA ($email || "."),"\n";
close(CA);
local $rv = $?;
local $out = &read_file_contents($outtemp);
unlink($outtemp);
if (!-r $certtemp || !-r $keytemp || $?) {
	# Failed .. return error
	return &text('csr_ekey', "<pre>$out</pre>");
	}

# Save as domain owner
&open_tempfile_as_domain_user($d, CERT, ">$certfile");
&print_tempfile(CERT, &read_file_contents($certtemp));
&close_tempfile_as_domain_user($d, CERT);
&open_tempfile_as_domain_user($d, KEY, ">$keyfile");
&print_tempfile(KEY, &read_file_contents($keytemp));
&close_tempfile_as_domain_user($d, KEY);

return undef;
}

# generate_certificate_request(csrfile, keyfile, size, days, country, state,
# 			       city, org, orgunit, commonname, email, &altnames,
# 			       &domain)
# Generates a new self-signed cert, and stores it in the given csr and key
# files. Returns undef on success, or an error message on failure.
sub generate_certificate_request
{
local ($csrfile, $keyfile, $size, $days, $country, $state, $city, $org,
       $orgunit, $common, $email, $altnames, $d) = @_;
&foreign_require("webmin", "webmin-lib.pl");
$size ||= $config{'key_size'} || $webmin::default_key_size;
$days ||= 1825;

# Prepare for SSL alt names
local $flag;
if ($altnames && @$altnames) {
	$flag = &setup_openssl_altnames([ @$altnames, $common ], 0);
	}

# Generate the key
local $keytemp = &transname();
local $out = &backquote_command("openssl genrsa -out ".quotemeta($keytemp)." $size 2>&1 </dev/null");
local $rv = $?;
if (!-r $keytemp || $rv) {
	return &text('csr_ekey', "<pre>$out</pre>");
	}
&open_tempfile_as_domain_user($d, KEY, ">$keyfile");
&print_tempfile(KEY, &read_file_contents($keytemp));
&close_tempfile_as_domain_user($d, KEY);

# Generate the matching CSR
local $outtemp = &transname();
local $csrtemp = &transname();
&open_execute_command(CA, "openssl req $flag -new -key ".quotemeta($keytemp)." -out ".quotemeta($csrtemp)." >$outtemp 2>&1", 0);
print CA ($country || "."),"\n";
print CA ($state || "."),"\n";
print CA ($city || "."),"\n";
print CA ($org || "."),"\n";
print CA ($orgunit || "."),"\n";
print CA ($common || "*"),"\n";
print CA ($email || "."),"\n";
print CA ".\n";
print CA ".\n";
close(CA);
local $rv = $?;
local $out = &read_file_contents($outtemp);
unlink($outtemp);
if (!-r $csrtemp || $rv) {
	return &text('csr_ecsr', "<pre>$out</pre>");
	}

# Copy into place
&open_tempfile_as_domain_user($d, CERT, ">$csrfile");
&print_tempfile(CERT, &read_file_contents($csrtemp));
&close_tempfile_as_domain_user($d, CERT);
return undef;
}

# setup_openssl_altnames(&altnames, self-signed)
# Creates a temporary openssl.cnf file for generating a cert with alternate
# names. Returns the additional command line parameters for openssl to use it.
sub setup_openssl_altnames
{
local ($altnames, $self) = @_;
local @alts = &unique(@$altnames);
local $temp = &transname();
local $sconf = &find_openssl_config_file();
$sconf || &error($text{'cert_esconf'});
&copy_source_dest($sconf, $temp);

# Make sure subjectAltNames is set in .cnf file, in the right places
local $lref = &read_file_lines($temp);
local $i = 0;
local $found_req = 0;
local $found_ca = 0;
local $altline = "subjectAltName=".join(",", map { "DNS:$_" } @alts);
foreach my $l (@$lref) {
	if ($l =~ /^\s*\[\s*v3_req\s*\]/ && !$found_req) {
		splice(@$lref, $i+1, 0, $altline);
		$found_req = 1;
		}
	if ($l =~ /^\s*\[\s*v3_ca\s*\]/ && !$found_ca) {
		splice(@$lref, $i+1, 0, $altline);
		$found_ca = 1;
		}
	$i++;
	}
# If v3_req or v3_ca sections are missing, add at end
if (!$found_req) {
	push(@$lref, "[ v3_req ]", $altline);
	}
if (!$found_ca) {
	push(@$lref, "[ v3_ca ]", $altline);
	}

# Add copyall line if needed
local $i = 0;
local $found_copy = 0;
local $copyline = "copy_extensions=copyall";
foreach my $l (@$lref) {
	if (/^\s*\#*\s*copy_extensions\s*=/) {
		$l = $copyline;
		$found_copy = 1;
		last;
		}
	elsif (/^\s*\[\s*CA_default\s*\]/) {
		$found_ca = $i;
		}
	$i++;
	}
if (!$found_copy) {
	if ($found_ca) {
		splice(@$lref, $found_ca+1, 0, $copyline);
		}
	else {
		push(@$lref, "[ CA_default ]", $copyline);
		}
	}

&flush_file_lines($temp);
local $flag = "-config $temp -reqexts v3_req";
if ($self) {
	$flag .= " -reqexts v3_ca";
	}
return $flag;
}

# obtain_lock_ssl(&domain)
# Lock the Apache config file for some domain, and the Webmin config
sub obtain_lock_ssl
{
local ($d) = @_;
return if (!$config{'ssl'});
&obtain_lock_anything($d);
&obtain_lock_web($d);
if ($main::got_lock_ssl == 0) {
	local @sfiles = ($ENV{'MINISERV_CONFIG'} ||
		         "$config_directory/miniserv.conf",
		        $config_directory =~ /^(.*)\/webmin$/ ?
		         "$1/usermin/miniserv.conf" :
			 "/etc/usermin/miniserv.conf");
	foreach my $f (@sfiles) {
		&lock_file($f);
		}
	@main::got_lock_ssl_files = @sfiles;
	}
$main::got_lock_ssl++;
}

# release_lock_web(&domain)
# Un-lock the Apache config file for some domain, and the Webmin config
sub release_lock_ssl
{
local ($d) = @_;
return if (!$config{'ssl'});
&release_lock_web($d);
if ($main::got_lock_ssl == 1) {
	foreach my $f (@main::got_lock_ssl_files) {
		&unlock_file($f);
		}
	}
$main::got_lock_ssl-- if ($main::got_lock_ssl);
&release_lock_anything($d);
}

$done_feature_script{'ssl'} = 1;

1;

