#!/bin/sh

QOI_REF_DIR=qoi-reference
QOI_BENCH_SUITE=qoi-benchmark-suite

check_installed() {
    if ! type "$1" &> /dev/null; then
	echo "$1 command not found - aborting"
	exit 1
    else
	echo "$1 command found - OK"
    fi
}

check_installed "git"
check_installed "wget"
check_installed "tar"

# Download reference implementation
if [ ! -d "$QOI_REF_DIR" ]; then
    echo "Qoi reference not found - fetching"
    git clone --depth=1 https://github.com/phoboslab/qoi ${QOI_REF_DIR}
else
    echo "Qoi reference exists - skipping"
fi

# Download std_image
if [ ! -f "${QOI_REF_DIR}/stb_image.h" ]; then
    echo "stb_image.h not found - fetching"
    wget https://raw.githubusercontent.com/nothings/stb/refs/heads/master/stb_image.h -O ${QOI_REF_DIR}/stb_image.h
else
    echo "stb_image.h exists - skipping"
fi
if [ ! -f "${QOI_REF_DIR}/stb_image_write.h" ]; then
    echo "stb_image_write.h not found - fetching"
    wget https://raw.githubusercontent.com/nothings/stb/refs/heads/master/stb_image_write.h -O ${QOI_REF_DIR}/stb_image_write.h
else
    echo "stb_image_write.h exists - skipping"
fi

# Download benchmark suite
if [ ! -d "${QOI_BENCH_SUITE}" ]; then
    echo "Qoi benchmark suite not found - fetching"
    wget https://qoiformat.org/benchmark/qoi_benchmark_suite.tar
    tar -xf qoi_benchmark_suite.tar
    mv images ${QOI_BENCH_SUITE}
    rm -f qoi_benchmark_suite.tar
else
    echo "Qoi benchmark suite exists - skipping"
fi

echo "Initialization finished!"
