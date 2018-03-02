#!/usr/bin/env perl
use strict;
use warnings;
use Cwd;
use lib exists($ENV{'GALACTICUS_ROOT_V094'}) ? $ENV{'GALACTICUS_ROOT_V094'}.'/perl' : cwd().'/perl';
use Date::Format;
use XML::Simple;
use MIME::Lite;
use Net::SMTP::SSL;
use Data::Dumper;
use File::Slurp qw( slurp );
use File::Find;
use Term::ReadKey;
use System::Redirect;
use Galacticus::Launch::PBS;

# Run a suite of tests on the Galacticus code.
# Andrew Benson (19-Aug-2010).

# Read in any configuration options.
my $config;
if ( -e "galacticusConfig.xml" ) {
    my $xml = new XML::Simple;
    $config = $xml->XMLin("galacticusConfig.xml");
}

# Identify e-mail options for this host.
my $emailConfig;
my $smtpPassword;
if ( exists($config->{'email'}->{'host'}->{$ENV{'HOSTNAME'}}) ) {
    $emailConfig = $config->{'email'}->{'host'}->{$ENV{'HOSTNAME'}};
} elsif ( exists($config->{'email'}->{'host'}->{'default'}) ) {
    $emailConfig = $config->{'email'}->{'host'}->{'default'};
} else {
    $emailConfig->{'method'} = "sendmail";
}
if ( $emailConfig->{'method'} eq "smtp" && exists($emailConfig->{'passwordFrom'}) ) {
    # Get any password now.
    if ( $emailConfig->{'passwordFrom'} eq "input" ) {
	print "Please enter your e-mail SMTP password:\n";
	$smtpPassword = &getPassword;
    }
    elsif ( $emailConfig->{'passwordFrom'} eq "kdewallet" ) {
	my $appName          = "Galacticus";
	my $folderName       = "glc-test-all";
	require Net::DBus;
	my $bus           = Net::DBus->find;
	my $walletService = $bus->get_service("org.kde.kwalletd");
	my $walletObject  = $walletService->get_object("/modules/kwalletd");
	my $walletID      = $walletObject->open("kdewallet",0,$appName);
	if ( $walletObject->hasEntry($walletID,$folderName,"smtpPassword",$appName) == 1 ) {
	    $smtpPassword = $walletObject->readPassword($walletID,$folderName,"smtpPassword",$appName); 
	} else {
	    print "Please enter your e-mail SMTP password:\n";
	    $smtpPassword = &getPassword;
	    $walletObject->writePassword($walletID,$folderName,"smtpPassword",$smtpPassword,$appName); 
	}
    }
}

# Open a log file.
my $logFile = "testSuite/allTests.log";
open(lHndl,">".$logFile);

# Clean up previous build.
system("rm -rf work/build/*");

# Create a directory for test suite outputs.
system("rm -rf testSuite/outputs");
system("mkdir -p testSuite/outputs");

# Write header to log file.
print lHndl ":-> Running test suite:\n";
print lHndl "    -> Host:\t".$ENV{'HOSTNAME'}."\n";
print lHndl "    -> Time:\t".time2str("%a %b %e %T (%Z) %Y", time)."\n";

# Stack to be used for PBS jobs.
my @jobStack;

# Set options for PBS launch.
my %pbsOptions =
    (
     pbsJobMaximum       => 100,
     submitSleepDuration =>   1,
     waitSleepDuration   =>  10
    );

# Define a list of executables to run. Each hash must give the name of the executable and should specify whether or not the
# executable should be run inside of Valgrind (this is useful for detecting errors which lead to misuse of memory but which don't
# necessary cause a crash).
my @executablesToRun = (
    {
	name     => "tests.nodes.exe",                                                    # Tests of Galacticus nodes.
	valgrind => 0
    },
    {
	name     => "tests.parameters.exe",                                               # Tests of parameter input.
	valgrind => 0
    },
    {
	name     => "tests.IO.HDF5.exe",                                                  # Tests of HDF5 IO routines.
	valgrind => 0
    },
    {
	name     => "tests.IO.XML.exe",                                                   # Tests of XML IO routines.
	valgrind => 0
    },
    {
	name     => "tests.ODE_solver.exe",                                               # Tests of ODE solver routines.
	valgrind => 0
    },
    {
	name     => "tests.random.exe",                                                   # Tests of random number generators.
	valgrind => 0
    },
    {
	name     => "tests.arrays.exe",                                                   # Tests of array functions.
	valgrind => 0
    },
    {
	name     => "tests.meshes.exe",                                                   # Tests of mesh functions.
	valgrind => 0
    },
    {
	name     => "tests.comparisons.exe",                                              # Tests of comparison functions.
	valgrind => 0
    },
    {
	name     => "tests.geometry.coordinate_systems.exe",                              # Tests of coordinate system functions.
	valgrind => 0
    },
    {
	name     => "tests.hashes.exe",                                                   # Tests of hashing utilities.
	valgrind => 0
    },
    {
	name     => "tests.hashes.perfect.exe",                                           # Tests of perfect hashing utilities.
	valgrind => 0
    },
    {
	name     => "tests.regular_expressions.exe",                                      # Tests of regular expression utilities.
	valgrind => 0
    },
    {
	name     => "tests.hashes.cryptographic.exe",                                     # Tests of cryptographic hashing utilities.
	valgrind => 0
    },
    {
	name     => "tests.integration.exe",                                              # Tests of integration functions.
	valgrind => 0
    },
    {
	name     => "tests.integration2.exe",                                             # Tests of integration functions.
	valgrind => 0
    },
    {
	name     => "tests.tables.exe",                                                   # Tests of table functions.
	valgrind => 0
    },
    {
	name     => "tests.interpolation.exe",                                            # Tests of interpolation functions.
	valgrind => 0             
    },
    {
	name     => "tests.interpolation.2D.exe",                                         # Tests of 2D interpolation function.
	valgrind => 0
    },
    {
	name     => "tests.make_ranges.exe",                                              # Tests of numerical range building functions.
	valgrind => 0
    },
    {
	name     => "tests.mass_distributions.exe",                                       # Tests of mass distributions.
	valgrind => 0
    },
    {
	name     => "tests.math_special_functions.exe",                                   # Tests of mathematical special functions.
	valgrind => 0
    },
    {
	name     => "tests.math_distributions.exe",                                       # Tests of mathematical distributions.
	valgrind => 0
    },
    {
	name     => "tests.math.fast.exe",                                                # Tests of fast mathematical functions.
	valgrind => 0
    },
    {
	name     => "tests.root_finding.exe",                                             # Tests of root finding functions.
	valgrind => 0
    },
    {
	name     => "tests.search.exe",                                                   # Tests of searching functions.
	valgrind => 0
    },
    {
	name     => "tests.sort.exe",                                                     # Tests of sorting functions.
	valgrind => 0
    },
    {
	name     => "tests.string_utilities.exe",                                         # Tests of string handling utilities.
	valgrind => 0
    },
    {
	name     => "tests.vectors.exe",                                                  # Tests of vector functions.
	valgrind => 0
    },
    {
	name     => "tests.multi_counters.exe",                                           # Tests of multi-counters.
	valgrind => 0
    },
    {
	name     => "tests.tensors.exe",                                                  # Tests of tensor functions.
	valgrind => 0
    },
    {	name     => "tests.cosmic_age.exe",                                               # Tests of cosmic age calculations.
	valgrind => 0
    },
    {
	name     => "tests.spherical_collapse.open.exe",                                  # Tests of spherical collapse calculations.
	valgrind => 0
    },
    {
	name     => "tests.spherical_collapse.flat.exe",                                  # .
	valgrind => 0
    },
    {
	name     => "tests.spherical_collapse.dark_energy.EdS.exe",                       # .
	valgrind => 0
    },
    {
	name     => "tests.spherical_collapse.dark_energy.open.exe",                      # .
	valgrind => 0
    },
    {
	name     => "tests.spherical_collapse.dark_energy.lambda.exe",                    # .
	valgrind => 0
    },
    {
	name     => "tests.spherical_collapse.dark_energy.constantEoSminusTwoThirds.exe", # .
	valgrind => 0
    },
    {
	name     => "tests.spherical_collapse.dark_energy.constantEoSminus0.6.exe",       # .
	valgrind => 0
    },
    {
	name     => "tests.spherical_collapse.dark_energy.constantEoSminus0.8.exe",       # .
	valgrind => 0
    },
    {
	name     => "tests.spherical_collapse.nonlinear.exe",                             # .
	valgrind => 0
    },
    {
	name     => "tests.linear_growth.cosmological_constant.exe",                      # Tests of linear growth factor.
	valgrind => 0
    },
    {
	name     => "tests.linear_growth.EdS.exe",                                        # .
	valgrind => 0
    },
    {
	name     => "tests.linear_growth.open.exe",                                       # .
 	valgrind => 0
    },
    {
	name     => "tests.linear_growth.dark_energy.exe",                                # .
	valgrind => 0
    },
    {
	name     => "tests.halo_mass_function.Tinker.exe",                                # Tests of dark matter halo mass functions.
 	valgrind => 0
    },
    {
	name     =>"tests.comoving_distance.exe",                                         # Tests of comoving distance calculations.
 	valgrind => 0
    },
    {
	name     => "tests.mass_accretion_history.Correa2015.exe",                        # Tests of mass accretion histories.
	valgrind => 0
    },
    {
	name     => "tests.Zhao2009_algorithms.dark_energy.exe",                          # Tests of Zhao et al. (2009) algorithms.
	valgrind => 0
    },
    {
	name     => "tests.Zhao2009_algorithms.EdS.exe",                                  # .
	valgrind => 0
    },
    {
	name     => "tests.Zhao2009_algorithms.open.exe",                                 # .
	valgrind => 0
    },
    {
	name     => "tests.NFW96_concentration.dark_energy.exe",                          # Tests of Navarro, Frenk & White (1996) halo concentration algorithm.
	valgrind => 0
    },
    {
	name     => "tests.Prada2011_concentration.exe",                                  # Tests of Prada et al. (2011) halo concentration algorithm.
	valgrind => 0
    },
    {
	name     => "tests.DiemerKravtsov2014_concentration.exe",                         # Tests of Diemer & Kravtsov (2014) halo concentration algorithm.
	valgrind => 0
    },
    {
	name     => "tests.concentration.Correa2015.exe",                                # Tests of Correa et al. (2015) halo concentration algorithm.
	valgrind => 0
    },
    {
	name     => "tests.kepler_orbits.exe",                                            # Keplerian orbital parameter conversions.
	valgrind => 0
    },
    {
	name     => "tests.abundances.exe",                                               # Abundances objects.
	valgrind => 0
    },
    {
	name     => "tests.sigma.exe",                                                    # Sigma(M).
	valgrind => 0
    },
    {
	name     => "tests.power_spectrum.exe",                                           # Power spectrum.
	valgrind => 0
    },
    {
	name     => "tests.black_hole_fundamentals.exe",                                  # Black hole fundamentals.
	valgrind => 0
    },
    {
	name     => "tests.bug745815.exe",                                                # Regresssions.
	valgrind => 0
    },
    {
	name     => "tests.tree_branch_destroy.exe",                                      # Tests of merger tree walking.
	valgrind => 1,
	valgrindOptions => "--undef-value-errors=no"
    },
    {
	name     => "tests.gaunt_factors.exe",                                            # Tests of Gaunt factors.
	valgrind => 0
    },
    {
	name     => "tests.cooling_functions.exe",                                        # Tests of cooling functions.
	valgrind => 0
    },
    {
	name     => "tests.accretion_disks.exe",                                          # Tests of accretion disks.
	valgrind => 0
    },
    {
	name     => "tests.dark_matter_profiles.exe",                                     # Tests of dark matter profiles.
	valgrind => 0
    }
    );

# Build all executables.
my %testBuildJob =
    (
     launchFile   => "testSuite/compileTests.pbs",
     label        => "testSuite-compileTests"    ,
     logFile      => "testSuite/compileTests.log",
     command      => "rm -rf ./work/build; make -j16 ".join(" ",map {$_->{'name'}} @executablesToRun),
     ppn          => 16,
     onCompletion => 
     {
	 function  => \&testCompileFailure,
	 arguments => [ "testSuite/compileTests.log", "Test code compilation" ]
     }
    );
push(@jobStack,\%testBuildJob);
&Galacticus::Launch::PBS::SubmitJobs(\%pbsOptions,@jobStack);
unlink("testSuite/compileTests.pbs");

# Launch all executables.
my @launchFiles;
@jobStack = ();
foreach my $executable ( @executablesToRun ) {
    # Generate the job.
    if ( -e $executable->{'name'} ) {
	(my $label = $executable->{'name'}) =~ s/\./_/;
	my $ppn = exists($executable->{'ppn'}) ? $executable->{'ppn'} : 1;
	my $launchFile = "testSuite/".$label.".pbs";
	push(@launchFiles,$launchFile);
	my %job =
	    (
	     launchFile   => $launchFile               ,
	     label        => "testSuite-".$label       ,
	     logFile      => "testSuite/".$label.".log",
	     ppn          => $ppn                      ,
	     onCompletion => 
	     {
		 function  => \&testFailure,
		 arguments => [ "testSuite/".$label.".log", "Test code: ".$executable->{'name'} ]
	     }
	    );
	if ( $executable->{'valgrind'} == 1 ) {	    
	    $job{'command'} = "valgrind --error-exitcode=1 ".$executable->{'valgrindOptions'}." ".$executable->{'name'};
	} else {
	    $job{'command'} = $executable->{'name'};
	}
	push(@jobStack,\%job);
    }
}
&Galacticus::Launch::PBS::SubmitJobs(\%pbsOptions,@jobStack);
unlink(@launchFiles);

# Build Galacticus itself.
@jobStack = ();
my %galacticusBuildJob =
    (
     launchFile   => "testSuite/compileGalacticus.pbs",
     label        => "testSuite-compileGalacticus"    ,
     logFile      => "testSuite/compileGalacticus.log",
     command      => "make -j16 all"                  ,
     ppn          => 16,
     onCompletion => 
     {
	 function  => \&testCompileFailure,
	 arguments => [ "testSuite/compileGalacticus.log", "Galacticus compilation" ]
     }
    );
push(@jobStack,\%galacticusBuildJob);
&Galacticus::Launch::PBS::SubmitJobs(\%pbsOptions,@jobStack);
unlink("testSuite/compileGalacticus.pbs");
my @launchPBS;
my @launchLocal;
if ( -e "./Galacticus.exe" ) {
    # Find all test scripts to run.
    my @testDirs = ( "testSuite" );
    find(\&runTestScript,@testDirs);
    # Run scripts that require us to launch them under PBS.
    &Galacticus::Launch::PBS::SubmitJobs(\%pbsOptions,@launchPBS);
    # Run scripts that can launch themselves using PBS.
    foreach ( @launchLocal ) {
	print           ":-> Running test script: ".$_."\n";
	print lHndl "\n\n:-> Running test script: ".$_."\n";
	&System::Redirect::tofile("cd testSuite; ".$_,"testSuite/allTests.tmp");
	print lHndl slurp("testSuite/allTests.tmp");
	unlink("testSuite/allTests.tmp");
    }
}

# Close the log file.
close(lHndl);

# Scan the log file for FAILED.
my $lineNumber = 0;
my @failLines;
open(lHndl,$logFile);
while ( my $line = <lHndl> ) {
    ++$lineNumber;
    if ( $line =~ m/FAILED/ ) {
	push(@failLines,$lineNumber);
    }
    if ( $line =~ m/SKIPPED/ ) {
	push(@failLines,$lineNumber);
    }
}
close(lHndl);
open(lHndl,">>".$logFile);
my $emailSubject = "Galacticus test suite log";
my $exitStatus;
if ( scalar(@failLines) == 0 ) {
    print lHndl "\n\n:-> All tests were successful.\n";
    print       "All tests were successful.\n";
    $emailSubject .= " [success]";
    $exitStatus = 0;
} else {
    print lHndl "\n\n:-> Failures found. See following lines in log file:\n\t".join("\n\t",@failLines)."\n";
    print "Failure(s) found - see ".$logFile." for details.\n";
    $emailSubject .= " [FAILURE]";
    $exitStatus = 1;
}
close(lHndl);

# If we have an e-mail address to send the log to, then do so.
if ( defined($config->{'contact'}->{'email'}) ) {
    if ( $config->{'contact'}->{'email'} =~ m/\@/ ) {
	# Get e-mail configuration.
	my $sendMethod = $emailConfig->{'method'};
	# Construct the message.
	my $message  = "Galacticus test suite log is attached.\n";
	my $msg = MIME::Lite->new(
	    From    => '',
	    To      => $config->{'contact'}->{'email'},
	    Subject => $emailSubject,
	    Type    => 'TEXT',
	    Data    => $message
	    );
	system("bzip2 -f ".$logFile);
	$msg->attach(
	    Type     => "application/x-bzip",
	    Path     => $logFile.".bz2",
	    Filename => "allTests.log.bz2"
	    );
	if ( $sendMethod eq "sendmail" ) {
	    $msg->send;
	}
	elsif ( $sendMethod eq "smtp" ) {
	    my $smtp; 
	    $smtp = Net::SMTP::SSL->new($config->{'email'}->{'host'}, Port=>465) or die "Can't connect";
	    $smtp->auth($config->{'email'}->{'user'},$smtpPassword) or die "Can't authenticate:".$smtp->message();
	    $smtp->mail( $config->{'contact'}->{'email'}) or die "Error:".$smtp->message();
	    $smtp->to( $config->{'contact'}->{'email'}) or die "Error:".$smtp->message();
	    $smtp->data() or die "Error:".$smtp->message();
	    $smtp->datasend($msg->as_string) or die "Error:".$smtp->message();
	    $smtp->dataend() or die "Error:".$smtp->message();
	    $smtp->quit() or die "Error:".$smtp->message();
	}
    }
}

exit $exitStatus;

sub runTestScript {
    # Run a test script.
    my $fileName = $_;
    chomp($fileName);

    # Test if this is a script to run.
    if ( $fileName =~ m/^test\-.*\.pl$/ && $fileName ne "test-all.pl" ) {
	system("grep -q launch.pl ".$fileName);
	if ( $? == 0 ) {
	    # This script will launch its own models.
	    push(
		@launchLocal,
		$fileName
		);
	} else {
	    # We need to launch this script.
	    (my $label = $fileName) =~ s/\.pl$//;
	    push(
		@launchPBS,
		{
		    launchFile   => "testSuite/".$label.".pbs",
		    label        => "testSuite-".$label       ,
		    logFile      => "testSuite/".$label.".log",
		    command      => "cd testSuite; ".$fileName,
		    ppn          => 16,
		    onCompletion => 
		    {
			function  => \&testFailure,
			arguments => [ "testSuite/".$label.".log", "Test script '".$label."'" ]
		    }
		}
		);
	}
    }
}

sub getPassword {
    # Read a password from standard input while echoing asterisks to the screen.
    ReadMode('noecho');
    ReadMode('raw');
    my $password = '';
    while (1) {
	my $c;
	1 until defined($c = ReadKey(-1));
	last if $c eq "\n";
	print "*";
	$password .= $c;
    }
    ReadMode('restore');
    print "\n";
    return $password;
}

sub testFailure {
    # Callback function which checks for failure of jobs run in PBS.
    my $logFile     = shift();
    my $jobMessage  = shift();
    my $jobID       = shift();
    my $errorStatus = shift();
    # Check for failure message in log file.
    if ( $errorStatus == 0 ) {
	system("grep -q FAIL ".$logFile);
	$errorStatus = 1
	    if ( $? == 0 );
    }
    # Report success or failure.
    if ( $errorStatus == 0 ) {
	# Job succeeded.
	print lHndl "SUCCESS: ".$jobMessage."\n";
	unlink($logFile);
    } else {
	# Job failed.
	print lHndl "FAILED: ".$jobMessage."\n";
	print lHndl "Job output follows:\n";
	print lHndl slurp($logFile);
    }
}

sub testCompileFailure {
    # Callback function which checks for failure of compile jobs run in PBS.
    my $logFile     = shift();
    my $jobMessage  = shift();
    my $jobID       = shift();
    my $errorStatus = shift();
    # Check for failure message in log file.
    if ( $errorStatus == 0 ) {
	system("grep -q FAIL ".$logFile);
	$errorStatus = 1
	    if ( $? == 0 );	
    }
    # Check for compiler warning message in log file.
    if ( $errorStatus == 0 ) {
	system("grep -q Warning: ".$logFile);
	if ( $? == 0 ) {
	    $errorStatus = 1;
	    $jobMessage = "Compiler warnings issued\n".$jobMessage;
	}
    }
    # Report success or failure.
    if ( $errorStatus == 0 ) {
	# Job succeeded.
	print lHndl "SUCCESS: ".$jobMessage."\n";
	unlink($logFile);
    } else {
	# Job failed.
	print lHndl "FAILED: ".$jobMessage."\n";
	print lHndl "Job output follows:\n";
	print lHndl slurp($logFile);
    }
}
