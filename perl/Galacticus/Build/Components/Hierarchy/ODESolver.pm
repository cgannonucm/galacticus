# Contains a Perl module which provides various ODE solver-related functions for component hierarchy parent classes.

package ODESolver;
my $galacticusPath;
if ( exists($ENV{"GALACTICUS_ROOT_V094"}) ) {
    $galacticusPath = $ENV{"GALACTICUS_ROOT_V094"};
    $galacticusPath .= "/" unless ( $galacticusPath =~ m/\/$/ );
} else {
    $galacticusPath = "./";
}
unshift(@INC, $galacticusPath."perl"); 
use strict;
use warnings;
use utf8;
use Text::Template 'fill_in_string';
require List::ExtraUtils;
require Fortran::Utils;
require Galacticus::Build::Components::Utils;
require Galacticus::Build::Components::DataTypes;

# Insert hooks for our functions.
%Galacticus::Build::Component::Utils::componentUtils = 
    (
     %Galacticus::Build::Component::Utils::componentUtils,
     hierarchyODESolver => 
     {
	 functions =>
	     [
	      \&Component_ODE_Name_From_Index
	     ]
     }
    );

sub Component_ODE_Name_From_Index {
    # Generate a function to return the name of a property given the index of that property in a generic component.
    my $build = shift();
    # Generate the function.
    my $function =
    {
	type        => "type(varying_string) => name",
	name        => "nodeComponentNameFromIndex",
	description => "Return the name of the property of given index for a {\\normalfont \\ttfamily nodeComponent} object.",
	modules     => 
	    [ 
	      "ISO_Varying_String"
	    ],
	variables   =>
	    [
	     {
		 intrinsic  => "class",
		 type       => "nodeComponent",
		 attributes => [ "intent(in   )" ],
		 variables  => [ "self" ]
	     },
	     {
		 intrinsic  => "integer",
		 attributes => [ "intent(inout)" ],
		 variables  => [ "count" ]
	     }
	    ]
    };
    # This generic (parent) node component class has no properties, so return an unknown name.
    $function->{'content'} = fill_in_string(<<'CODE', PACKAGE => 'code');
!GCC$ attributes unused :: self, count
name='?'
CODE
    # Insert a type-binding for this function into the treeNode type.
    push(
	@{$build->{'types'}->{'nodeComponent'}->{'boundFunctions'}},
	{
	    type        => "procedure", 
	    descriptor  => $function,
	    name        => "nameFromIndex", 
	    returnType  => "\\textcolor{red}{\\textless varying\\_string\\textgreater}", 
	    arguments   => "\\intzero\\ index\\argin"
	}
	);	    
}

1;
