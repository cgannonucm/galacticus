#!/usr/bin/env perl
my $galacticusPath;
if ( exists($ENV{"GALACTICUS_ROOT_V091"}) ) {
 $galacticusPath = $ENV{"GALACTICUS_ROOT_V091"};
 $galacticusPath .= "/" unless ( $galacticusPath =~ m/\/$/ );
} else {
 $galacticusPath = "./";
}
unshift(@INC,$galacticusPath."perl"); 
use strict;
use warnings;
use XML::Simple;
use UNIVERSAL 'isa';
use Data::Dumper;
require Fortran::Utils;

# Construct a unique string that defines the operation of a given module.
# Andrew Benson (10-April-2012)

# Get the source directory.
die('Usage: Make_Unique_Label_Functions.pl <sourceDir>') unless ( scalar(@ARGV) == 1 );
my $sourceDirectory = $ARGV[0]."/source";

# Open the output file.
open(oHndl,">./work/build/utility.input_parameters.unique_labels.inc"             );
open(vHndl,">./work/build/utility.input_parameters.unique_labels.visibilities.inc");

# Scan the source directory for source files.
opendir(dHndl,$sourceDirectory);
while ( my $fileName = readdir(dHndl) ) {
    # Initialize.
    my $processFile = 0;
    my $labelFunction;
    my %ignoreParameters;

    # Select Fortran source files.
    if ( $fileName =~ m/\.F90$/ ) {
	my $xmlBuffer;
	open(iHndl,$sourceDirectory."/".$fileName);
	while ( my $xmlLine = <iHndl> ) {
	    if ( $xmlLine =~ m/^\s*\!#(.*)/ ) {
		my $xmlLine = $1;
		$xmlBuffer = "" if ( $xmlLine =~ m/^\s*<(uniqueLabel)>\s*$/ );
		$xmlBuffer .= $xmlLine;
		if ( $xmlLine =~ m/^\s*<\/uniqueLabel>\s*$/ ) {
		    # Parse the XML.
		    my $xml = new XML::Simple;
		    my $uniqueLabel = $xml->XMLin($xmlBuffer);
		    $labelFunction = $uniqueLabel->{'function'};
		    if ( exists($uniqueLabel->{'ignore'}) ) {
			my @ignores;
			if ( UNIVERSAL::isa($uniqueLabel->{'ignore'},"ARRAY") ) {
			    @ignores = @{$uniqueLabel->{'ignore'}};
			} else {
			    push(@ignores,$uniqueLabel->{'ignore'});
			}
			foreach my $ignore ( @ignores ) {
			    $ignoreParameters{$ignore} = 1;
			}
		    }
		    $processFile = 1;
		}
	    }
	}
	close(iHndl);
    }

    # Process the file if necessary.
    if ( $processFile == 1 ) {

	# Initialize the definition code.
	my $definitionCode;
	
	# Get the equivalent object file.
	my $objectFile = "./work/build/".$fileName;
	$objectFile =~ s/\.F90$/.o/;

	# Get the name of the module supplied by this file.
	my $moduleFile = $objectFile;
	$moduleFile =~ s/\.o$/.m/;
	my $depFile = $objectFile;
	$depFile =~ s/\.o$/.d/;
	open(iHndl,$moduleFile);
	unless ( eof(iHndl) ) {
	    my $selfName = <iHndl>;
	    chomp($selfName);
	    close(iHndl);
	    $selfName =~ s/\.\/work\/build\/(.*)\.mod$/$1/;
	    
	    # Begin creating the function for the definition.
	    $definitionCode .= "function ".$labelFunction."(includeVersion,asHash)\n";
	    $definitionCode .= "  implicit none\n";
	    $definitionCode .= "  type(varying_string)                       :: ".$labelFunction."\n";
	    $definitionCode .= "  logical             , intent(in), optional :: includeVersion,asHash\n";
	    $definitionCode .= "  type(varying_string)                       :: parameterValue\n";
	    $definitionCode .= "  ".$labelFunction."=''\n";
	    
	    # Process the list of dependencies.
	    open(iHndl,$depFile);
	    while ( my $depName = <iHndl> ) {
		chomp($depName);
		$depName =~ s/\.\/work\/build\/(.*)\.o$/$1/;
		# Get the name of the associated module.
		my $moduleFile = "./work/build/".$depName.".m";
		open(jHndl,$moduleFile);
		unless ( eof(jHndl) ) {
		    my $moduleName = <jHndl>;
		    chomp($moduleName);
		    $moduleName       =~ s/\.\/work\/build\/(.*)\.mod$/$1/;
		    my $moduleCode    = "  ".$labelFunction."=".$labelFunction."//'::".$moduleName."'\n";	
		    my $hasParameters = 0;

		    # Scan the file for default parameter values.
		    my %defaultValues;
		    my $sourceFile = $sourceDirectory."/".$depName.".F90";
		    unless ( $depName eq "utility.input_parameters" ) {
			my $fileHandle;
			open($fileHandle,$sourceFile);
			until ( eof($fileHandle) ) {
			    # Grab the next Fortran line.
			    my $rawLine;
			    my $processedLine;
			    my $bufferedComments;
			    &Fortran_Utils::Get_Fortran_Line($fileHandle,$rawLine,$processedLine,$bufferedComments);
			    if ( $processedLine =~ m/Get_Input_Parameter/i ) {
				if ( $processedLine =~ m/defaultValue\s*=\s*(.*)[,\)]/i ) {
				    my $defaultValue = $1;
				    if ( $processedLine =~ m/Get_Input_Parameter\s*\(\s*'(.*)'/i ) {
					my $parameterName = $1;
					$defaultValues{$parameterName} = $defaultValue;
				    }
				}
			    }
			}
			close(sFile);
		    }

		    # Scan this file for parameters.
		    my $methodParameter;
		    my $methodValue;
		    my $xmlBuffer;
		    open(sFile,$sourceFile);
		    while ( my $line = <sFile> ) {
			# Find method activations.
			if ( $line =~ m/^\s*if\s*\(\s*([a-zA-Z0-9_]+)Method\s*==\s*\'([a-zA-Z0-9_\-\+]+)\'\s*\)/ ) {
			    $methodParameter = $1."Method";
			    $methodValue     = $2;
			}
			# Find XML blobs.
			if ( $line =~ m/^\s*(\!|\/\/)@(.*)/ ) {
			    my $xmlLine = $2;
			    $xmlBuffer = "" if ( $xmlLine =~ m/^\s*<(inputParameter)>\s*$/ );
			    $xmlBuffer .= $xmlLine;
			    if ( $xmlLine =~ m/^\s*<\/inputParameter>\s*$/ ) {
				# Parse the XML.
				my $xml = new XML::Simple;
				my $inputParameter = $xml->XMLin($xmlBuffer);
				unless ( exists($ignoreParameters{$inputParameter->{'name'}}) ) {
				    $moduleCode .= "  call Get_Input_Parameter_VarString('".$inputParameter->{'name'}."',parameterValue";
				    $moduleCode .= ",defaultValue='".$defaultValues{$inputParameter->{'name'}}."'" if ( exists($defaultValues{$inputParameter->{'name'}}) );
				    $moduleCode .= ",writeOutput=.false.)\n";
				    $moduleCode .= "  ".$labelFunction."=".$labelFunction."//'#".$inputParameter->{'name'}."['//parameterValue//']'\n";
				    $hasParameters = 1;
				}
			    }
			}
		    }
		    close(sFile);
		    if ( $hasParameters == 1 ) {
			if ( defined($methodParameter) ) {
			    $definitionCode .= "  call Get_Input_Parameter_VarString('".$methodParameter."',parameterValue";
			    $definitionCode .= ",defaultValue='".$defaultValues{$methodParameter}."'" if ( exists($defaultValues{$methodParameter}) );
			    $definitionCode .= ",writeOutput=.false.)\n";
			}
			$definitionCode .= "  if (parameterValue == '".$methodValue."') then\n"
			    if ( defined($methodParameter) );
			$definitionCode .= $moduleCode;
			$definitionCode .= "  end if\n"
			    if ( defined($methodParameter) );	
		    }
		}
		close(jHndl);
	    }
	    close(iHndl);
	    
	    # Finish the definition code.
	    $definitionCode .= "  if (present(includeVersion)) then\n";
	    $definitionCode .= "    if (includeVersion) ".$labelFunction."=".$labelFunction."//'_'//Galacticus_Version()\n";
	    $definitionCode .= "  end if\n";
	    $definitionCode .= "  if (present(asHash)) then\n";
	    $definitionCode .= "    if (asHash) ".$labelFunction."=Hash_MD5(".$labelFunction.")\n";
	    $definitionCode .= "  end if\n";
	    $definitionCode .= "  return\n";
	    $definitionCode .= "end function ".$labelFunction."\n\n";
	    
	    # Write the function definition to file.
	    print oHndl $definitionCode;
	    print vHndl "public :: ".$labelFunction."\n";
	} else {
	    close(iHndl);
	}	
    }
}
closedir(dHndl);

# Close the output files.
close(oHndl);
close(vHndl);

exit;
