# Contains a Perl module which implements processing of event directives.

package Galacticus::Build::SourceTree::Process::EventHooks;
use strict;
use warnings;
use utf8;
use Cwd;
use lib $ENV{'GALACTICUS_EXEC_PATH'}."/perl";
use Data::Dumper;
use XML::Simple;
use List::ExtraUtils;
use List::Util 'max';
use Fortran::Utils;
use Galacticus::Build::Directives;
use Text::Template 'fill_in_string';
use Digest::MD5 qw(md5_hex);

# Insert hooks for our functions.
$Galacticus::Build::SourceTree::Hooks::processHooks{'eventHooks'} = \&Process_EventHooks;

sub Process_EventHooks {
    # Get the tree.
    my $tree = shift();
    # Get an XML parser.
    my $xml = new XML::Simple();
    # Get code directive locations.
    my $directiveLocations = $xml->XMLin($ENV{'BUILDPATH'}."/directiveLocations.xml");
    # Walk the tree, looking for hook directives.
    my $node  = $tree;
    my $depth = 0;
    while ( $node ) {
	# Handle eventHookManger directives by building eventHook objects for all events.
	if ( $node->{'type'} eq "eventHookManager" && ! $node->{'directive'}->{'processed'} ) {
	    $node->{'directive'}->{'processed'} =  1;
	    # Find all hook directives.
	    my @hooks = map {&Galacticus::Build::Directives::Extract_Directives($_,'eventHook')} &List::ExtraUtils::as_array($directiveLocations->{'eventHook'}->{'file'});
	    # Create an object for each event hook.
	    foreach my $hook ( @hooks ) {
		# Skip hooks that are duplicates.
		next
		    if ( exists($hook->{'isDuplicate'}) && $hook->{'isDuplicate'} eq "yes" );
		# Determine the interface type for this hook.
		$code::interfaceType = &interfaceTypeGet($hook);
		my $hookObject;
		unless ( $code::interfaceType eq "Unspecified" ) {
		    # Parse the interface definition.
		    $code::declarations = $hook->{'interface'};
		    @code::arguments    = ();
		    open(my $declarations,"<",\$hook->{'interface'});
		    while ( ! eof($declarations) ) {
			&Fortran::Utils::Get_Fortran_Line($declarations,my $rawLine, my $processedLine, my $bufferedComments);
			foreach my $declarator ( keys(%Fortran::Utils::intrinsicDeclarations) ) {
			    if ( my @matches = ( $processedLine =~ $Fortran::Utils::intrinsicDeclarations{$declarator}->{'regEx'} ) ) {
				push(@code::arguments,&Fortran::Utils::Extract_Variables($matches[$Fortran::Utils::intrinsicDeclarations{$declarator}->{'variables'}],keepQualifiers => 0));
				last;
			    }
			}
		    }
		    close($declarations);
		    # Look for symbols to import.
		    $code::imports = "";
		    if ( exists($hook->{'import'}) ) {
			my $usesNode =
			{
			    type      => "moduleUse"
			};
			my @imports;
			foreach my $module ( &List::ExtraUtils::as_array($hook->{'import'}->{'module'}) ) {
			    my @symbolNames = split(/\s*,\s*/,$module->{'symbols'});
			    push(@imports,@symbolNames);
			    my %symbols;
			    foreach my $symbol ( @symbolNames ) {
				$symbols{$symbol} = 1;
			    }
			    $usesNode->{'moduleUse'}->{$module->{'name'}} =
			    {
				intrinsic => 0,
				only      => \%symbols
			    };
			}
			$code::imports = "  import ".join(", ",@imports)." \n";
			# Insert the modules.
			&Galacticus::Build::SourceTree::Parse::ModuleUses::AddUses($node->{'parent'},$usesNode);
		    }
		    # Build the required types and functions.
		    $hookObject = fill_in_string(<<'CODE', PACKAGE => 'code');

type, extends(hook) :: hook{$interfaceType}
   procedure(interface{$interfaceType}), pointer, nopass :: function_ => null()
end type hook{$interfaceType}
 
type, extends(eventHook) :: eventHook{$interfaceType}
  private
 contains
  !![
  <methods>
    <method method="attach"     description="Attach a hook to the event."                         />
    <method method="isAttached" description="Return true if the object is attached to this event."/>
    <method method="detach"     description="Detach a hook from the event."                       />
  </methods>
  !!]
  procedure :: attach     => eventHook{$interfaceType}Attach
  procedure :: isAttached => eventHook{$interfaceType}IsAttached
  procedure :: detach     => eventHook{$interfaceType}Detach
end type eventHook{$interfaceType}

abstract interface
 subroutine interface{$interfaceType}(self{scalar(@arguments) > 0 ? ",".join(",",@arguments) : ""})
{$imports}
  class(*), intent(inout) :: self
{$declarations}
 end subroutine interface{$interfaceType}
end interface
CODE
		    $code::location = &Galacticus::Build::SourceTree::Process::SourceIntrospection::Location($node,$node->{'line'});
		    my $attacher = fill_in_string(<<'CODE', PACKAGE => 'code');
  subroutine eventHook{$interfaceType}Attach(self,object_,function_,openMPThreadBinding,label,dependencies)
    !!{
    Attach an object to an event hook.
    !!}
    use    :: Error  , only : Error_Report
    !$ use :: OMP_Lib, only : OMP_Get_Ancestor_Thread_Num, OMP_Get_Level
    implicit none
    class     (eventHook{$interfaceType}         ), intent(inout)                            :: self
    class     (*                                 ), intent(in   ), target                    :: object_
    type      (enumerationOpenMPThreadBindingType), intent(in   ), optional                  :: openMPThreadBinding
    character (len=*                             ), intent(in   ), optional                  :: label
    class     (dependency                        ), intent(in   ), optional   , dimension(:) :: dependencies
    procedure (interface{$interfaceType}         )                                           :: function_
    type      (hookList                          )               , allocatable, dimension(:) :: hooksTmp
    type      (hook{$interfaceType}              )                            , pointer      :: hook_
    !$ integer                                                                               :: i
    !![
    <optionalArgument name="openMPThreadBinding" defaultsTo="openMPThreadBindingNone" />
    !!]

    ! Resize the array of hooks.
    if (allocated(self%hooks_)) then
       call move_alloc(self%hooks_,hooksTmp)
       allocate(self%hooks_(self%count_+1))
       self%hooks_(1:self%count_)=hooksTmp
       deallocate(hooksTmp)
    else
       allocate(self%hooks_(1))
    end if
    ! Create the new hook.
    allocate(hook_)
    hook_%object_             => object_
    hook_%function_           => function_
    hook_%openMPThreadBinding =  openMPThreadBinding_
    if (present(label)) then
       hook_%label=label
    else
       hook_%label=""
    end if
    !$ if (hook_%openMPThreadBinding == openMPThreadBindingAtLevel .or. hook_%openMPThreadBinding == openMPThreadBindingAllLevels) then
    !$    hook_%openMPLevel=OMP_Get_Level()
    !$    allocate(hook_%openMPThread(0:hook_%openMPLevel))
    !$    do i=0,hook_%openMPLevel
    !$       hook_%openMPThread(i)=OMP_Get_Ancestor_Thread_Num(i)
    !$    end do
    !$ end if
    ! Insert the hook into the list.
    self%hooks_(self%count_+1)%hook_ => hook_
    ! Increment the count of hooks into this event and resolve dependencies.
    self%count_=self%count_+1
    call self%resolveDependencies(hook_,dependencies)
    return
  end subroutine eventHook{$interfaceType}Attach
CODE
		    my $attacherTree  = &Galacticus::Build::SourceTree::ParseCode($attacher,"null()");
		    my @attacherNodes = &Galacticus::Build::SourceTree::Children($attacherTree);
		    &Galacticus::Build::SourceTree::InsertPostContains($node->{'parent'},\@attacherNodes);
		    my $detacher = fill_in_string(<<'CODE', PACKAGE => 'code');
  subroutine eventHook{$interfaceType}Detach(self,object_,function_)
    !!{
    Attach an object to an event hook.
    !!}
    use :: Error, only : Error_Report
    implicit none
    class    (eventHook{$interfaceType}), intent(inout)               :: self
    class    (*                        ), intent(in   ), target       :: object_
    procedure(                         )                              :: function_
    type     (hookList                 ), allocatable  , dimension(:) :: hooksTmp
    integer                                                           :: i
    
    if (allocated(self%hooks_)) then
       do i=1,self%count_
          select type (hook_ => self%hooks_(i)%hook_)
          type is (hook{$interfaceType})
             if (associated(hook_%object_,object_).and.associated(hook_%function_,function_)) then
                deallocate(self%hooks_(i)%hook_)
                if (self%count_ > 1) then
                   call move_alloc(self%hooks_,hooksTmp)
                   allocate(self%hooks_(self%count_-1))
                   if (i >           1) self%hooks_(1:          i-1)=hooksTmp(1  :          i-1)
                   if (i < self%count_) self%hooks_(i:self%count_-1)=hooksTmp(i+1:self%count_  )
                   deallocate(hooksTmp)
                else
                   deallocate(self%hooks_)
                end if
                self%count_=self%count_-1
                return
             end if
          end select
       end do
    end if
    call Error_Report('object/function not attached to this event'//{$location})
    return
  end subroutine eventHook{$interfaceType}Detach
CODE
		    my $detacherTree  = &Galacticus::Build::SourceTree::ParseCode($detacher,"null()");
		    my @detacherNodes = &Galacticus::Build::SourceTree::Children($detacherTree);
		    &Galacticus::Build::SourceTree::InsertPostContains($node->{'parent'},\@detacherNodes);
		    my $isAttacher = fill_in_string(<<'CODE', PACKAGE => 'code');
  logical function eventHook{$interfaceType}IsAttached(self,object_,function_)
    !!{
    Return true if an object is attached to an event hook.
    !!}
    use :: Error, only : Error_Report
    implicit none
    class    (eventHook{$interfaceType}), intent(inout)          :: self
    class    (*                        ), intent(in   ), target  :: object_
    procedure(                         )                         :: function_
    integer                                                      :: i
    
    if (allocated(self%hooks_)) then
       do i=1,self%count_
          select type (hook_ => self%hooks_(i)%hook_)
          type is (hook{$interfaceType})
             if (associated(hook_%object_,object_).and.associated(hook_%function_,function_)) then
                eventHook{$interfaceType}IsAttached=.true.
                return
             end if
          end select
       end do
    end if
    eventHook{$interfaceType}IsAttached=.false.
    return
  end function eventHook{$interfaceType}IsAttached
CODE
		    my $isAttacherTree  = &Galacticus::Build::SourceTree::ParseCode($isAttacher,"null()");
		    my @isAttacherNodes = &Galacticus::Build::SourceTree::Children($isAttacherTree);
		    &Galacticus::Build::SourceTree::InsertPostContains($node->{'parent'},\@isAttacherNodes);
		    &Galacticus::Build::SourceTree::SetVisibility($node->{'parent'},"hook".$code::interfaceType,"public");
	        }
		$hookObject .= "type(eventHook".$code::interfaceType."), public :: ".$hook->{'name'}."Event\n";
		$hookObject .= "type(eventHook".$code::interfaceType.")         :: ".$hook->{'name'}."Event_, ".$hook->{'name'}."EventBackup\n";
		$hookObject .= "!\$omp threadprivate (".$hook->{'name'}."Event,".$hook->{'name'}."EventBackup)\n";
		my $hookTree = &Galacticus::Build::SourceTree::ParseCode($hookObject,"null()");
		my @hookNodes = &Galacticus::Build::SourceTree::Children($hookTree);
		&Galacticus::Build::SourceTree::InsertAfterNode($node,\@hookNodes);
	    }
            # Build a function to perform copy out of the current event lists before entering a new OpenMP parallel region.
            my $copyOut = fill_in_string(<<'CODE', PACKAGE => 'code');
subroutine eventsHooksFilterCopyOut_()
   implicit none
   call copyLock%set()
CODE
            foreach my $hook ( @hooks ) {
		$copyOut .= "   ".$hook->{'name'}."Event_=".$hook->{'name'}."Event\n";
            }
            $copyOut .= fill_in_string(<<'CODE', PACKAGE => 'code');
   return
end subroutine eventsHooksFilterCopyOut_
CODE
            my $copyOutNode   =
            {
		type       => "code",
		content    => $copyOut,
		firstChild => undef(),
                source     => "Galacticus::Build::SourceTree::Process::EventHooks::Process_EventHooks()",
                line       => 1
	    };
            &Galacticus::Build::SourceTree::InsertPostContains($node->{'parent'},[$copyOutNode]);
            # Build a function to perform copy in of the current event lists on entering a new OpenMP parallel region.
            my $copyIn = fill_in_string(<<'CODE', PACKAGE => 'code');
subroutine eventsHooksFilterCopyIn_()
   implicit none
CODE
            foreach my $hook ( @hooks ) {
		$copyIn .= "   ".$hook->{'name'}."Event      =".$hook->{'name'}."Event_\n";
		$copyIn .= "   ".$hook->{'name'}."EventBackup=".$hook->{'name'}."Event_\n";
            }
            $copyIn .= fill_in_string(<<'CODE', PACKAGE => 'code');
   return
end subroutine eventsHooksFilterCopyIn_
CODE
            my $copyInNode   =
            {
		type       => "code",
		content    => $copyIn,
		firstChild => undef(),
                source     => "Galacticus::Build::SourceTree::Process::EventHooks::Process_EventHooks()",
                line       => 1
	    };
            &Galacticus::Build::SourceTree::InsertPostContains($node->{'parent'},[$copyInNode]);
            # Build a function to perform restore of the current event lists before leaving a OpenMP parallel region.
            my $restore = fill_in_string(<<'CODE', PACKAGE => 'code');
subroutine eventsHooksFilterRestore_()
   implicit none
CODE
            foreach my $hook ( @hooks ) {
		$restore .= "   ".$hook->{'name'}."Event      =".$hook->{'name'}."EventBackup\n";
            }
            $restore .= fill_in_string(<<'CODE', PACKAGE => 'code');
   return
end subroutine eventsHooksFilterRestore_
CODE
            my $restoreNode   =
            {
		type       => "code",
		content    => $restore,
		firstChild => undef(),
                source     => "Galacticus::Build::SourceTree::Process::EventHooks::Process_EventHooks()",
                line       => 1
	    };
            &Galacticus::Build::SourceTree::InsertPostContains($node->{'parent'},[$restoreNode]);
	    # Build a function to finalize copy of the current event lists on entering a new OpenMP parallel region.
            my $copyDone = fill_in_string(<<'CODE', PACKAGE => 'code');
subroutine eventsHooksFilterCopyDone_()
   implicit none
   call copyLock%unset()
   return
end subroutine eventsHooksFilterCopyDone_
CODE
            my $copyDoneNode   =
            {
		type       => "code",
		content    => $copyDone,
		firstChild => undef(),
                source     => "Galacticus::Build::SourceTree::Process::EventHooks::Process_EventHooks()",
                line       => 1
	    };
            &Galacticus::Build::SourceTree::InsertPostContains($node->{'parent'},[$copyDoneNode]);
            # Build a function to filter the list of hooks on entering a new OpenMP parallel region.
            my $filter = fill_in_string(<<'CODE', PACKAGE => 'code');
subroutine eventsHooksFilterFunction_()
   implicit none
CODE
            foreach my $hook ( @hooks ) {
		$filter .= "   call ".$hook->{'name'}."Event%filter()\n";
            }
            $filter .= fill_in_string(<<'CODE', PACKAGE => 'code');
   return
end subroutine eventsHooksFilterFunction_
CODE
            my $filterNode   =
            {
		type       => "code",
		content    => $filter,
		firstChild => undef(),
                source     => "Galacticus::Build::SourceTree::Process::EventHooks::Process_EventHooks()",
                line       => 1
	    };
            &Galacticus::Build::SourceTree::InsertPostContains($node->{'parent'},[$filterNode]);
	}
	# Handle eventHook directives by creating code to call any hooked functions.
	if ( $node->{'type'} eq "eventHook" && ! $node->{'directive'}->{'processed'} ) {
	    $node->{'directive'}->{'processed'} =  1;
	    # Insert the module.
	    my $usesNode =
	    {
		type      => "moduleUse",
		moduleUse =>
		{
		    Events_Hooks     =>
		    {
			intrinsic => 0,
			all       => 1
		    },
                    Error =>
		    {
			intrinsic => 0,
			all       => 1
		    },
                    OMP_Lib          =>
		    {
			intrinsic => 0,
			openMP    => 1,
			all       => 1
		    }
		}
	    };
	    &Galacticus::Build::SourceTree::Parse::ModuleUses::AddUses($node->{'parent'},$usesNode);
	    # Insert required variables.
	    my @declarations =
		(
                 {
                     intrinsic     => "integer",
		     variables     => [ $node->{'directive'}->{'name'}."Iterator" ]
		 }
		);
	    &Galacticus::Build::SourceTree::Parse::Declarations::AddDeclarations($node->{'parent'},\@declarations);
	    # Create the code.
	    $code::interfaceType = &interfaceTypeGet($node->{'directive'});
	    $code::callWith      = exists($node->{'directive'}->{'callWith'}) ? ",".$node->{'directive'}->{'callWith'} : "";
	    $code::eventName     = $node->{'directive'}->{'name'};
	    my $eventHookCode    = fill_in_string(<<'CODE', PACKAGE => 'code');
if ({$eventName}Event%count() > 0) then
  do {$eventName}Iterator=1,{$eventName}Event%count()
     select type (hook_ => {$eventName}Event%hooks_({$eventName}Iterator)%hook_)
     type is (hook{$interfaceType})
       call hook_%function_(hook_%object_{$callWith})
     end select
  end do
end if
CODE
	    # Insert the code.
	    my $newNode =
	    {
		type       => "code",
		content    => $eventHookCode,
		firstChild => undef(),
		source     => "Galacticus::Build::SourceTree::Process::EventHooks::Process_EventHooks()",
		line       => 1
	    };
	    &Galacticus::Build::SourceTree::InsertAfterNode($node,[$newNode]);
	}
	# Handle OpenMP parallel sections by adding copyin of our hooks, followed by per-thread filtering.
	if ( $node->{'type'} eq "openMP" && $node->{'name'} eq "parallel" && ! $node->{'isCloser'} && ! exists($node->{'eventFilterInserted'}) ) {
	    $node->{'eventFilterInserted'} =  1;
	    # Find all hook directives.
	    my @hooks = map {&Galacticus::Build::Directives::Extract_Directives($_,'eventHook')} &List::ExtraUtils::as_array($directiveLocations->{'eventHook'}->{'file'});
	    # Insert the required module uses.
	    my $usesNode =
	    {
		type      => "moduleUse",
		moduleUse => 
		{
		    Events_Filters =>
		    {
			intrinsic => 0,
			only => {
			    eventsHooksFilterFunction => 1,
			    eventsHooksFilterCopyOut  => 1,
			    eventsHooksFilterCopyIn   => 1,
			    eventsHooksFilterCopyDone => 1
			}
		    }
		}
	    };
	    &Galacticus::Build::SourceTree::Parse::ModuleUses::AddUses($node->{'parent'},$usesNode);
	    # Insert a call to our filter function.
	    my $copyOutNode =
	    {
		type       => "code",
		content    => "call eventsHooksFilterCopyOut()\n",
		firstChild => undef(),
		source     => "Galacticus::Build::SourceTree::Process::EventHooks::Process_EventHooks()",
		line       => 1
	    };
	    &Galacticus::Build::SourceTree::InsertBeforeNode($node,[$copyOutNode]);
	    # Insert a call to our filter function.
	    my $filterCode = fill_in_string(<<'CODE', PACKAGE => 'code');
call eventsHooksFilterCopyIn()
!$omp barrier
!$omp single
call eventsHooksFilterCopyDone()
!$omp end single
call eventsHooksFilterFunction()
CODE
	    my $filterNode =
	    {
		type       => "code",
		content    => $filterCode,
		firstChild => undef(),
		source     => "Galacticus::Build::SourceTree::Process::EventHooks::Process_EventHooks()",
		line       => 1
	    };
	    &Galacticus::Build::SourceTree::InsertAfterNode($node,[$filterNode]);

	}
	# Handle OpenMP end parallel sections by adding restore of our hooks.
	if ( $node->{'type'} eq "openMP" && $node->{'name'} eq "parallel" && $node->{'isCloser'} && ! exists($node->{'eventFilterInserted'}) ) {
	    $node->{'eventFilterInserted'} =  1;
	    # Find all hook directives.
	    my @hooks = map {&Galacticus::Build::Directives::Extract_Directives($_,'eventHook')} &List::ExtraUtils::as_array($directiveLocations->{'eventHook'}->{'file'});
	    # Insert the required module uses.
	    my $usesNode =
	    {
		type      => "moduleUse",
		moduleUse => 
		{
		    Events_Filters =>
		    {
			intrinsic => 0,
			only => {
			    eventsHooksFilterRestore => 1
			}
		    }
		}
	    };
	    &Galacticus::Build::SourceTree::Parse::ModuleUses::AddUses($node->{'parent'},$usesNode);
	    # Insert a call to our restore function.
	    my $restoreNode =
	    {
		type       => "code",
		content    => "call eventsHooksFilterRestore()\n",
		firstChild => undef(),
		source     => "Galacticus::Build::SourceTree::Process::EventHooks::Process_EventHooks()",
		line       => 1
	    };
	    &Galacticus::Build::SourceTree::InsertBeforeNode($node,[$restoreNode]);
	}
	$node = &Galacticus::Build::SourceTree::Walk_Tree($node,\$depth);
    }
}

sub interfaceTypeGet {
    my $hook = shift();
    my $interfaceType;
    if ( exists($hook->{'interface'}) ) {
	$interfaceType = md5_hex($hook->{'name'});
   } else {
	$interfaceType = "Unspecified";
    }
    return $interfaceType;
}

1;
