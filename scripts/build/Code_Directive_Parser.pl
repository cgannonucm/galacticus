#!/usr/bin/env perl
use XML::Simple;
use Data::Dumper;
use Switch;
use lib './perl';
use System::Redirect;

# Scans source code for "!#" directives and generates a Makefile.

# Define the source directory.
if ( $#ARGV != 0 ) {die "Usage: Code_Directive_Parser.pl sourcedir"};
$sourcedir = $ARGV[0];
$sourcedirs[0] = $sourcedir."/source";

# Specify verbosity.
$verbosity = 0;

# Create XML object.
$xml = new XML::Simple;

# Initialize hashes.
undef(%includeDirectives);

# Open the source directory.
foreach $srcdir ( @sourcedirs ) {
    opendir(indir,$srcdir) or die "Can't open the source directory: #!";
    while ($fname = readdir indir) {	
	if ( $fname =~ m/\.[fF](90)??t??$/ && $fname !~ m/^\.\#/ ) {
	    $fullname = "$srcdir/$fname";
	    open(infile,$fullname) or die "Can't open input file: #!";
	    while ($line = <infile>) {
		if ( $line =~ m/^\s*!\#\s+(<\s*([a-zA-Z]+)+.*>)\s*$/ ) {
		    $xmlCode = $1."\n";
		    $xmlTag  = $2;
		    # Read ahead until a matching close tag is found.
		    unless ( $xmlCode =~  m/\/>/ ) {
			$nextLine = "";
			until ( $nextLine =~ m/<\/$xmlTag>/ || eof(infile) ) {
			    $nextLine = <infile>;
			    $nextLine =~ s/^\s*!\#\s+//;
			    $xmlCode .= $nextLine;
			}
		    }
		    $data = $xml->XMLin($xmlCode);
		    if ( $verbosity == 1 ) {
			print "$fname : $xmlCode\n";
			print Dumper($data);
		    }
		    # Act on the directive.
		    $xmlOutput = new XML::Simple (NoAttr=>1, RootName=>$xmlTag);
		    switch ( $xmlTag ) {
			case ( "include" ) {
			    if ( ${$data}{'content'} =~ m/^\s*include\s*["'](.+)["']/i ) {
				($fileName = "work/build/".$1) =~ s/\.inc$/\.Inc/;
				${$data}{'fileName'} = $fileName;
			    }
			    delete(${$data}{'content'});
			    ${$includeDirectives{${$data}{'directive'}.".".${$data}{'type'}}}{'fileName'} = $fileName;
			    ${$includeDirectives{${$data}{'directive'}.".".${$data}{'type'}}}{'xml'} = $xmlOutput->XMLout($data);
			}
		    }
		}
	    }
	}
	close(infile);
    }
    closedir(indir);
}

# Output the Makefile
open(makefileHndl,">./work/build/Makefile_Directives");
foreach $directive ( keys(%includeDirectives) ) {
    ($fileName = ${$includeDirectives{$directive}}{'fileName'}) =~ s/\.inc$/\.Inc/;
    print makefileHndl $fileName.": ./work/build/".$directive.".xml\n";
    print makefileHndl "\t./scripts/build/Build_Include_File.pl ".$sourcedir." ./work/build/".$directive.".xml\n";
    print makefileHndl "\n";
    open(xmlHndl,">./work/build/".$directive.".xml.tmp");
    print xmlHndl ${$includeDirectives{$directive}}{'xml'};
    close(xmlHndl);
    &SystemRedirect::tofile("diff -q  $sourcedir/work/build/".$directive.".xml.tmp $sourcedir/work/build/".$directive.".xml","/dev/null");
    if ( $? == 0 ) {
	system("rm -f $sourcedir/work/build/".$directive.".xml.tmp");
    } else {
	system("mv $sourcedir/work/build/".$directive.".xml.tmp $sourcedir/work/build/".$directive.".xml");
    }
}
close(makefileHndl);
exit;
