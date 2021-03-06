#!/bin/bash -e
export PATH=/usr/local/bin/:$PATH

source /opt/ros/kinetic/setup.sh
# Get the directory of this script.
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

PACKAGE="--all"
DEPENDENCIES=""
COMPILER="gcc"
RUN_TESTS=true
RUN_CPPCHECK=true
CHECKOUT_CATKIN_SIMPLE=true

DEPS=src/dependencies

# Download / update dependencies.
for i in "$@"
do
case $i in
  -p=*|--packages=*)
  PACKAGES="${i#*=}"
  ;;
  -d=*|--dependencies=*)
  DEPENDENCIES="${i#*=}"
  ;;
  -c=*|--compiler=*)
  COMPILER="${i#*=}"
  ;;
  -t|--no_tests)
  RUN_TESTS=false
  ;;
  -n|--no_cppcheck)
  RUN_CPPCHECK=false
  ;;
  -s|--no_catkinsimple)
  CHECKOUT_CATKIN_SIMPLE=false
  ;;
  *)
    echo "Usage: run_build [{-d|--dependencies}=dependency_github_url.git]"
    echo "  [{-p|--packages}=packages]"
    echo "  [{--compiler}=gcc/clang]"
    echo "  [{-t|--no_tests} skip gtest execution]"
    echo "  [{-c|--no_cppcheck} skip cppcheck execution]"
    echo "  [{-s|--no_catkinsimple} skip checking out catkin simple]"
  ;;
esac
done

cd $WORKSPACE
echo "-----------------------------"
# Locate the main folder everything is checked out into.
REP=$(find . -maxdepth 3 -type d -name .git -a \( -path "./$DEPS/*" -prune -o -print -quit \) )
if [ -n "${REP}" ]; then
  REP=$(dirname "${REP}")
  repo_url_self=$(cd "${REP}" && git config --get remote.origin.url)
  echo "Found my repository at ${REP}: repo_url_self=${repo_url_self}."
fi

echo "-----------------------------"

# If no packages are defined, we select all packages that are non-dependencies.
# Get all package xmls in the tree, which are non dependencies.
if [ -z "$PACKAGES" ]; then
  all_package_xmls="$(find . -name "package.xml" | grep -v "$DEPS")"
  echo "Auto discovering packages to build."

  for package_xml in ${all_package_xmls}
  do
    # Read the package name from the xml.
    package="$(echo 'cat //name/text()' | xmllint --shell ${package_xml} | grep -Ev "/|-")"
    pkg_path=${package_xml%package.xml}
    if [ -f "${pkg_path}/CATKIN_IGNORE" ]; then
      echo "Skipping package $package since the package contains CATKIN_IGNORE."
    elif [ -f "${pkg_path}/CI_IGNORE" ]; then
      echo "Skipping package $package since the package contains CI_IGNORE."
    else
      PACKAGES="${PACKAGES} $package"
      echo "Added package $package."
    fi
  done
  echo "Found $PACKAGES by autodiscovery."
fi

# If the package has a dependencies.yaml file, we overwrite the build-job config dep list.
if [ -f "${REP}/dependencies.yaml" ]; then
  echo "Rosinstall file: ${REP}/dependencies.yaml found, overwriting specified dependencies."
  DEPENDENCIES=$(pwd)/${REP}/dependencies.yaml
fi

# If the build job specifies a VCS yaml file, we overwrite the build-job config dep list.
if [ -z "$rosinstall_file" ]; then
  echo "No VCS yaml file specified, using dependency list from build-job config."
else
  echo "VCS yaml file: $rosinstall_file specified, overwriting specified dependencies."
  DEPENDENCIES=$rosinstall_file
fi

echo "Parameters:"
echo "-----------------------------"
echo "Workspace: ${WORKSPACE}"
echo "Packages: ${PACKAGES}"
echo "Dependencies: ${DEPENDENCIES}"
echo "Execute integration tests: ${RUN_TESTS}"
echo "Run cppcheck: ${RUN_CPPCHECK}"
echo "Checkout catkin simple: ${CHECKOUT_CATKIN_SIMPLE}"
echo "-----------------------------"

# If we are on a mac we only support Apple Clang for now.
unamestr=`uname`
if [[ "$unamestr" == 'Darwin' ]]; then
  echo "Running on OSX setting compiler to clang."
  COMPILER="clang"
fi

echo "Compilers:"
echo "-----------------------------"
if [ "$COMPILER" == "gcc" ]
then
  gcc -v
  g++ -v
  export CC=gcc
  export CXX=g++
fi
if [ "$COMPILER" == "clang" ]
then
  clang -v
  export CC=clang
  export CXX=clang++
fi
echo "-----------------------------"

# Dependencies: Install using rosinstall or list of repositories from the build-job config.

if $CHECKOUT_CATKIN_SIMPLE; then
  CATKIN_SIMPLE_URL=git@github.com:catkin/catkin_simple.git
else
  CATKIN_SIMPLE_URL=""
fi
mkdir -p $WORKSPACE/$DEPS && cd $WORKSPACE/$DEPS

if [[ $DEPENDENCIES == *.yaml ]]
then
  source /opt/ros/kinetic/setup.sh
  cd $WORKSPACE/src
  catkin_init_workspace || true
  
  # Make a separate workspace for the deps, so we can exclude them from cppcheck etc.
  mkdir -p $WORKSPACE/$DEPS
  cd $WORKSPACE/$DEPS
  
  echo "Dependencies specified by VCS yaml file.";
  
  echo "Yaml to use:"
  cat $DEPENDENCIES
  vcs-import < $DEPENDENCIES
else
  DEPENDENCIES="${DEPENDENCIES} ${CATKIN_SIMPLE_URL}"

  for dependency_w_branch in ${DEPENDENCIES}
  do
    cd $WORKSPACE/$DEPS
    
    source $DIR/modules/parse_dependency.sh

    if [ -d $foldername ]; then
      echo "Package $foldername exists, running: git fetch $depth_args && git checkout ${revision} && git submodule update --recursive"
      (cd "$foldername" && git fetch $depth_args && git checkout ${revision} && git submodule update --recursive)
    else
      echo "Package $foldername does not exist, running: clone $clone_args $depth_args --recursive \"$dependency\""
      git clone $clone_args $depth_args --recursive "$dependency"
      if [ -z "$branch" ]; then # this means we know a specific (nameless) commit to checkout
        (cd "$foldername" && git checkout ${revision} && git submodule update --recursive)
      fi
    fi
  done
fi

cd $WORKSPACE

# Prepare cppcheck ignore list. We want to skip dependencies.
CPPCHECK_PARAMS="src --xml --enable=missingInclude,performance,style,portability,information -j8 -ibuild -i$DEPS"

#Now run the build.
if $DIR/run_build_catkin_or_rosbuild ${RUN_TESTS} ${PACKAGES}; then
  if [[ "$unamestr" == 'Linux' ]]; then
    echo "Running cppcheck $CPPCHECK_PARAMS ..."
    # Run cppcheck excluding dependencies.
    cd $WORKSPACE
    if $RUN_CPPCHECK; then
      rm -f cppcheck-result.xml
      cppcheck $CPPCHECK_PARAMS 2> cppcheck-result.xml
    fi
  fi
else
  exit 1
fi


