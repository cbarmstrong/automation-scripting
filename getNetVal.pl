#!/usr/bin/perl

use strict;
use warnings;
use File::Basename;
use lib dirname($0)."/Modules/lib/site_perl/5.8.8/";
use lib dirname($0)."/Modules";
use Getopt::Long;
use MWUtils ":ALL";

my $parms = { opts => '' };
my $result = GetOptions( $parms, "opts=s");
for my $o (split(/,/,$parms->{opts})){
    my ($k,$v) = split /=/, $o;
    $parms->{$k}=$v unless defined $parms->{$k};
}

getNetParms($parms);
print "$parms->{requestedKey}=".$parms->{"$parms->{requestedKey}"}."\n";

