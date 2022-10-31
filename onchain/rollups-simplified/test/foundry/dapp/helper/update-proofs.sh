#!/usr/bin/env bash

set -euo pipefail

# Go to the helper folder
cd "${BASH_SOURCE%/*}"

# Get path to machine emulator repository
if [ -n "${MACHINE_EMULATOR_REPO:-}" ]
then
    machine_emulator_repo="${MACHINE_EMULATOR_REPO}"
else
    rollups_repo=`git rev-parse --show-toplevel`
    machine_emulator_repo=${rollups_repo}/../machine-emulator
fi

# Color numbers
GREEN=32
MAGENTA=35
CYAN=36

# Echoes with color
echo2() {
    printf "\033[0;$1m"
    shift
    echo "$@"
    printf "\033[0;00m"
}

# Check for command line arguments
if [ $# -ge 1 ] && [ $1 == "--setup" ]
then
    echo2 $CYAN "Setting up..."

    if [ -d "${machine_emulator_repo}" ]
    then
        echo
        echo2 $GREEN "1. Machine emulator repository found. Cloning skipped."
    else
        echo
        echo2 $GREEN "1. Machine emulator repository not found. Cloning it..."
        echo

        # Clone the machine-emulator repository
        git clone https://github.com/cartesi-corp/machine-emulator.git -- "${machine_emulator_repo}"
    fi

    # Go to machine emulator repository
    pushd "${machine_emulator_repo}" >/dev/null

    echo
    echo2 $GREEN "2. Switching machine emulator branch to 'feature/gen-proofs'..."
    echo

    # Change branch
    git checkout feature/gen-proofs

    echo
    echo2 $GREEN "3. Building Docker image..."
    echo

    # Build Docker image
    cd tools/gen-proofs
    docker build -t cartesi/server-manager-gen-proofs:devel .

    echo
    echo2 $GREEN "4. Installing Python package..."
    echo

    # Install Python package through pip
    pip3 install base64-to-hex-converter

    # Return to rollups repository
    popd >/dev/null

    echo
    echo2 $CYAN "All set up!"
    echo

    # Do not update proofs, just set up.
    exit 0
fi

# Get absolute path of helper folder
helper_folder=`pwd`

# Create a temporary file for storing the test output
log_file=`mktemp`

echo2 $CYAN "Updating proofs..."

echo
echo2 $GREEN "1. Running forge tests..."

# Run the tests and pipe the output to a file
forge test -vv --match-contract CartesiDAppTest > "${log_file}" || true

# Echo an error message before exiting
failure() {
  local lineno=$1
  local msg=$2
  echo2 $MAGENTA "Failed at ${lineno}: ${msg}"
}

# Install a trap to help debugging
trap 'failure ${LINENO} "${BASH_COMMAND}"' ERR

echo
echo2 $GREEN "2. Processing logs and updating vouchers JSON..."

# Process the log file with awk and generate a jq filter
jq_filter=`awk -f jqFilter.awk -- "${log_file}"`

# Remove log file
rm "${log_file}"

# Run the jq filter on vouchers.json
jq_output=`jq "${jq_filter}" vouchers.json`

# Update vouchers.json
echo "${jq_output}" > vouchers.json

echo
echo2 $GREEN "3. Generating script to be run on docker image..."
echo

# Generate script with vouchers
npx ts-node genScript.ts | sed 's/^/* /'

echo
echo2 $GREEN "4. Running docker image to generate epoch status..."
echo

# Go to gen-proofs folder
pushd "${machine_emulator_repo}/tools/gen-proofs" >/dev/null

# Copy script to gen-proofs folder
cp "${helper_folder}/gen-proofs.sh" gen-proofs.sh

# Run docker to generate proofs
docker run -it --rm \
    --name gen-proofs \
    -v "`pwd`/gen-proofs.sh:/opt/gen-proofs/gen-proofs.sh" \
    -v "`pwd`/output:/opt/gen-proofs/output" \
    -w /opt/gen-proofs \
    cartesi/server-manager-gen-proofs:devel \
    ./gen-proofs.sh

echo
echo2 $GREEN "5. Processing epoch status and updating voucher proofs..."

# Decode strings in epoch status from Base64 to hexadecimal
# Format the output with jq so that git diffs are smoother
python3 -m b64to16 output/epoch-status.json | jq > "${helper_folder}/voucherProofs.json"

# Go back to the helper folder
popd >/dev/null

echo
echo2 $GREEN "6. Generating Solidity contracts for each proof..."
echo

# Generate Solidity libraries with proofs
npx ts-node genProofLibraries.ts | sed 's/^/* /'

echo
echo2 $CYAN "Proofs were updated!"