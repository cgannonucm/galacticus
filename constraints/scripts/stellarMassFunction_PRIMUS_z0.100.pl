#!/usr/bin/env perl
use strict;
use warnings;
use Cwd;
use lib exists($ENV{'GALACTICUS_ROOT_V094'}) ? $ENV{'GALACTICUS_ROOT_V094'}.'/perl' : cwd().'/perl';
use PDL;
use PDL::NiceSlice;
use XML::Simple;
use Galacticus::Options;
use Galacticus::Constraints::MassFunctions;

# Compute likelihood (and make a plot) for a Galacticus model given the PRIMUS z=0.100 stellar mass function data from
# Moustakas et al. (2013; http://adsabs.harvard.edu/abs/2013ApJ...767...50M),

# Data structure to hold the specification for our mass function.
my $massFunctionConfig;

# Get name of input and output files.
die("stellarMassFunction_PRIMUS_z0.100.pl <galacticusFile> [options]") unless ( scalar(@ARGV) >= 1 );
$massFunctionConfig->{'self'          } = $0;
$massFunctionConfig->{'galacticusFile'} = $ARGV[0];
# Create a hash of named arguments.
my $iArg = -1;
my %arguments;
&Galacticus::Options::Parse_Options(\@ARGV,\%arguments);

# Specify the properties of this mass function.
my $entry                                    = 0;
$massFunctionConfig->{'redshift'           } = pdl 0.100;
$massFunctionConfig->{'analysisLabel'      } = "primusStellarMassFunctionZ0.100";
$massFunctionConfig->{'discrepancyFileName'} = "discrepancy".ucfirst($massFunctionConfig->{'analysisLabel'}).".hdf5";
$massFunctionConfig->{'massType'           } = "massStellar";
$massFunctionConfig->{'massErrorRandomDex' } = 0.07;
$massFunctionConfig->{'xRange'             } = "5.0e8:2.0e12";
$massFunctionConfig->{'yRange'             } = "5.0e-8:1.0e-1";
$massFunctionConfig->{'xLabel'             } = "\$M_\\star\$ [\$M_\\odot\$]";
$massFunctionConfig->{'yLabel'             } = "\${\\rm d}n/{\\rm d}\\log M_\\star\$ [Mpc\$^{-3}\$]";
$massFunctionConfig->{'title'              } = "Stellar mass function at \$z\\approx 0.100\$";

# Read the observed data.
my $xml          = new XML::Simple;
my $observations = $xml->XMLin("data/observations/massFunctionsStellar/Stellar_Mass_Function_PRIMUS_2013.xml");
my $columns      = ${$observations->{'stellarMassFunction'}}[$entry]->{'columns'};
$massFunctionConfig->{'x'                           } = pdl @{$columns->{'stellarMass' }->{'datum'}};
$massFunctionConfig->{'y'                           } = pdl @{$columns->{'massFunction'}->{'datum'}};
$massFunctionConfig->{'yUpperError'                 } = pdl @{$columns->{'upperError'  }->{'datum'}};
$massFunctionConfig->{'yLowerError'                 } = pdl @{$columns->{'lowerError'  }->{'datum'}};
$massFunctionConfig->{'yIsPer'                      } = "log10";
$massFunctionConfig->{'xScaling'                    } = $columns->{'stellarMass' }->{'scaling'};
$massFunctionConfig->{'yScaling'                    } = $columns->{'massFunction'}->{'scaling'};
$massFunctionConfig->{'observationLabel'            } = $observations->{'label'};
$massFunctionConfig->{'hubbleConstantObserved'      } = $observations->{'cosmology'          }->{'hubble'          };
$massFunctionConfig->{'omegaMatterObserved'         } = $observations->{'cosmology'          }->{'omegaMatter'     };
$massFunctionConfig->{'omegaDarkEnergyObserved'     } = $observations->{'cosmology'          }->{'omegaDarkEnergy' };
$massFunctionConfig->{'cosmologyScalingMass'        } = $columns     ->{'stellarMass'        }->{'cosmologyScaling'};
$massFunctionConfig->{'cosmologyScalingMassFunction'} = $columns     ->{'stellarMassFunction'}->{'cosmologyScaling'}; 

# Construct the mass function.
&Galacticus::Constraints::MassFunctions::Construct(\%arguments,$massFunctionConfig);

exit;
