#!/usr/bin/env perl
use strict;
use warnings;
use Cwd;
use lib exists($ENV{'GALACTICUS_ROOT_V094'}) ? $ENV{'GALACTICUS_ROOT_V094'}.'/perl' : cwd().'/perl';
use Galacticus::Path;

# Find the maximum likelihood estimate of the covariance matrix for the Li & White (2009) SDSS stellar mass function.
# Andrew Benson (05-July-2012)

# Simply run the generic script with our config file as argument.
system(&galacticusPath()."constraints/dataAnalysis/scripts/covarianceMatrix.pl ".&galacticusPath()."constraints/dataAnalysis/stellarMassFunction_SDSS_z0.07/covarianceMatrixControl.xml");

exit;
