#!/usr/bin/perl -w

# Copyright (C) 2018 Thomas More - tmore1@gmx.com
# c14sync is free software, released under the terms of the
# Perl Artistic License 2.0, contained in the included file 'LICENSE'
# c14sync comes with ABSOLUTELY NO WARRANTY
# The c14sync homepage is https://github.com/tmo1/c14sync
# c14sync is fully documented in its README, FAQ, and example configuration file

use strict;

use File::Spec;
use ConfigReader::Simple;
use Getopt::Std;
use URI;
use REST::Client;
use JSON;
use File::Rsync;

# process command line options

my ($program_name, $program_version) = ('c14sync', 0.1);
my %opts;
getopts('rRAv:s:a:t:i:l:c:', \%opts);

# set defaults for (some) undefined options

my %defaults = ('v' => 1, 'R' => 1, 'A' => 1);
$opts{$_} //= $defaults{$_} foreach keys %defaults;
my $default_conf_file = File::Spec->catfile($ENV{'HOME'}, ".$program_name.conf");

# process config file

my $conf_file = $opts{'c'} // (-f $default_conf_file ? $default_conf_file : undef);
if ($conf_file) {
	print "Loading configuration file: $conf_file\n" if $opts{'v'} >= 2;	
	my $config = ConfigReader::Simple->new($conf_file);
	my %opts_map = (verbose => 'v', safe_name => 's', archive_name => 'a', identity => 'i', local_dir => 'l', token => 't', reverse => 'r', rearchive => 'R', autorearchive => 'A');
	foreach ($config->directives) {if (exists $opts_map{$_}) {$opts{$opts_map{$_}} = $config->get($_)} else {print "Undefined configuration file directive '$_' - ignoring.\n";}}
}

$opts{'s'} || die "No safe name specified - aborting.\n";
$opts{'a'} || die "No archive name specified - aborting.\n";
$opts{'l'} || die "No local directory specified - aborting.\n";
$opts{'t'} || die "No API token specified - aborting.\n";

# setup REST client object

my ($api_host, $api_basepath) = ("https://api.online.net", "/api/v1");
my $c14_basepath = "$api_basepath/storage/c14";
my $client = REST::Client->new({host => $api_host});
$client->addHeader('Authorization', "Bearer $opts{'t'}");

# find archive

print "Checking whether safe / archive combination \"$opts{'s'} / $opts{'a'}\" exists.\nGetting list of archives ...\n" if $opts{'v'} >= 2;
my $archive_list = &get("${c14_basepath}/archive");
print "Got list of archives.\n" if $opts{'v'} >= 2;
my ($archive, $safe, $flag);
foreach (@{$archive_list}) {
	next unless ($_->{'name'} eq $opts{'a'});
	$archive = &get($_->{'$ref'});
	$safe = &get($archive->{'safe'}{'$ref'});
	next unless ($safe->{'name'} eq $opts{'s'});
	die "Safe / archive combination \"$opts{'s'} / $opts{'a'}\" is not unique - aborting.\n" if $flag;
	$flag = 1;
}
die "Safe/archive combination \"$opts{'s'}/$opts{'a'}\" not found - aborting.\n" unless $flag;
print "Archive found - API URI:\t$archive->{'$ref'}\n" if $opts{'v'} >= 1;

# open archive if it isn't yet open

unless ($archive->{'bucket'}) {
	print "Archive is not open - attempting to open it.\n" if $opts{'v'} >= 1;
	print "Getting ssh key ids ...\n" if $opts{'v'} >= 2;
	my $ssh_keys = &get("${api_basepath}/user/key/ssh");
	print "Got ssh key ids.\n" if $opts{'v'} >= 2;
	# 'Locations' aren't documented anywhere, and I have no idea what they are, so we just use the first one
	print "Getting archive locations ...\n" if $opts{'v'} >= 2;	
	my $locations = &get("$archive->{'$ref'}/location");
	print "Got archive locations.\n" if $opts{'v'} >= 2;
	print "Unarchiving ...\n" if $opts{'v'} >= 1;
	&post("$archive->{'$ref'}/unarchive", encode_json({location_id => ${$locations}[0]{'uuid_ref'}, rearchive => (($opts{'A'} && !$opts{'r'}) ? 1 : 0), protocols => ['SSH'], ssh_keys => [map {$_->{'uuid_ref'}} @{$ssh_keys}]}), {'Content-Type' => 'application/json'});
	print "Unarchiving successful. Waiting for bucket to be ready ...\n" if $opts{'v'} >= 1;
	do {
		sleep 15;
		$archive = &get($archive->{'$ref'});
		print "Archive status:\t$archive->{'status'}\n" if $opts{'v'} >= 2;
	} until ($archive->{'status'} eq 'active');
	print "Bucket is ready.\n" if $opts{'v'} >= 1;
	}
	else {print "Archive is open.\n" if $opts{'v'} >= 1}

# setup rsync command

my $bucket = $archive->{'bucket'};
my $ssh_uri = URI->new($bucket->{'credentials'}[0]{'uri'});
my ($ssh_host, $ssh_port) = ($ssh_uri->host, $ssh_uri->port);
my @rsync_options = ('archive' => 1, 'compress' => 1, delete => 1, 'rsh' => "ssh -l $bucket->{'credentials'}[0]{'login'} -p $ssh_port -o 'UserKnownHostsFile = /dev/null' -o 'StrictHostKeyChecking = no'" . (defined $opts{'i'} ? " -i $opts{'i'}" : ''));
push @rsync_options, ('verbose' => $opts{'v'}) if defined $opts{'v'};
my $rsync = File::Rsync->new(@rsync_options);

# execute rsync

print "Calling rsync ...\n" if $opts{'v'} >= 1;
my ($src, $dest) = ($opts{'l'}, "$ssh_host:/buffer");
($src, $dest) = ("$dest/", $src) if $opts{'r'};
$rsync->exec('src' => $src, 'dest' => $dest) || die "Rsync failed.\nRsync stderr:\n", $rsync->err, "\n\n";
print $rsync->out if $opts{'v'} >= 1;
print "Rsync succeeded.\n" if $opts{'v'} >= 1;
exit if ($opts{'r'} or !$opts{'R'}); # we don't rearchive after a reverse rsync, or if told not to do so

# rearchive

print "Rearchiving ...\n" if $opts{'v'} >= 1;
&post("$archive->{'$ref'}/archive", encode_json({duplicates => 1}), {'Content-Type' => 'application/json'});
print "Rearchiving succeeded.\n" if $opts{'v'} >= 1;

# delete old archive

if (defined $archive->{'size'}) {
	print "Attempting to delete old archive. Waiting for archive to be ready ...\n" if 	$opts{'v'} >= 1;
	do {
		sleep 15;
		$archive = &get($archive->{'$ref'});
		print "Archive status:\t$archive->{'status'}\n" if $opts{'v'} >= 2;
	} until ($archive->{'status'} eq 'active');
	print "Deleting old archive ...\n" if $opts{'v'} >= 1;
	&delete($archive->{'$ref'});
	print "Archive deletion succeeded.\n" if $opts{'v'} >= 1;
}
else {
	print "Parameter 'size' not found in original archive - there is apparently no old archive to delete.\n" if $opts{'v'} >= 1;
}

exit;

# API HTTP verb subroutines

sub get {
	print "Making API call (GET) to URI:\t$_[0]\n" if $opts{'v'} >= 2;	
	return decode_json $client->responseContent() if ($client->GET($_[0])->responseCode() eq '200');	
	my $error = $client->responseContent();
	unless (defined $client->responseHeader('Client-Warning') && $client->responseHeader('Client-Warning') eq "Internal response") {
		$error = decode_json $error;
		$error = "$error->{'error'}\nError code\t$error->{'code'}";
	} 
	die "Error!\nHTTP code:\t", $client->responseCode(), "\nError message\t$error\n";
}

sub post {
	print "Making API call (POST) to URI:\t$_[0]\n" if $opts{'v'} >= 2;
	return if ($client->POST(@_)->responseCode() eq '202');	
	my $error = $client->responseContent();
	unless (defined $client->responseHeader('Client-Warning') && $client->responseHeader('Client-Warning') eq "Internal response") {
		$error = decode_json $error;
		$error = "$error->{'error'}\nError code\t$error->{'code'}";
	} 
	die "\nError!\nHTTP code:\t", $client->responseCode(), "\nError message\t$error\n";
}

sub delete {
	print "Making API call (DELETE) to URI:\t$_[0]\n" if $opts{'v'} >= 2;
	return if ($client->DELETE(@_)->responseCode() eq '204');
	my $error = $client->responseContent();
	unless (defined $client->responseHeader('Client-Warning') && $client->responseHeader('Client-Warning') eq "Internal response") {
		$error = decode_json $error;
		$error = "$error->{'error'}\nError code\t$error->{'code'}";
	} 
	die "\nError!\nHTTP code:\t", $client->responseCode(), "\nError message\t$error\n";
}