#!/usr/bin/perl

use strict;
use warnings;
use File::Basename;
use Getopt::Long;
use lib dirname($0)."/Modules/lib/site_perl/5.8.8/";
use lib dirname($0)."/Modules";
use Term::Menu;
use MWUtils ":ALL";
use MWActions ":ALL";
use MWBuilders ":ALL";

use Data::Dumper;

my $parms = { opts => '' };
my $result = GetOptions( $parms, "opts=s");
for my $o (split(/,/,$parms->{opts})){
    my ($k,$v) = split /=/, $o;
    $parms->{$k}=$v unless defined $parms->{$k};
}

if(defined $parms->{tasks}){
    logger("Setting up tasks from properties",5);
    for my $task ( split /:\s*/, $parms->{tasks} ){    
        logger("Setting up $task from properties",5);
        propCmdBuilder($parms,$task);
    }
}
if(defined $parms->{command} and not defined $parms->{tasks}){
    logger("Setting up command line tasks",5);
    for my $command ( split /:\s*/, $parms->{command} ){
        logger("Setting up $command",5);
        argsCmdBuilder($parms,$command);
    }
}

if(@{$parms->{current_task_list}}){
    executeTaskList($parms);
} else{
    logger("No parms supplied");
}
