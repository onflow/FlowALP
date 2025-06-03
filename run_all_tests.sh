#!/bin/bash

echo "Running All TidalProtocol Tests..."
echo "================================="

TOTAL_TESTS=0
PASSING_TESTS=0
FAILING_TESTS=0

# Array to store test results
declare -a TEST_RESULTS

# Run each test file
for test_file in cadence/tests/*.cdc; do
    # Skip helper files
    if [[ "$test_file" == *"test_helpers.cdc" ]] || [[ "$test_file" == *"test_setup.cdc" ]]; then
        continue
    fi
    
    filename=$(basename "$test_file")
    echo -n "Running $filename... "
    
    # Run test and capture output
    output=$(flow test "$test_file" 2>&1)
    
    # Count PASS and FAIL
    passes=$(echo "$output" | grep -c "PASS:")
    fails=$(echo "$output" | grep -c "FAIL:")
    
    if [ $passes -gt 0 ] || [ $fails -gt 0 ]; then
        TOTAL_TESTS=$((TOTAL_TESTS + passes + fails))
        PASSING_TESTS=$((PASSING_TESTS + passes))
        FAILING_TESTS=$((FAILING_TESTS + fails))
        
        echo "✓ ($passes/$((passes + fails)) passing)"
        TEST_RESULTS+=("$filename: $passes/$((passes + fails)) passing")
    else
        echo "✗ (Error or no tests)"
        TEST_RESULTS+=("$filename: ERROR")
    fi
done

echo ""
echo "================================="
echo "SUMMARY"
echo "================================="
echo "Total Tests Run: $TOTAL_TESTS"
echo "Passing Tests: $PASSING_TESTS"
echo "Failing Tests: $FAILING_TESTS"
if [ $TOTAL_TESTS -gt 0 ]; then
    PASS_RATE=$(echo "scale=2; $PASSING_TESTS * 100 / $TOTAL_TESTS" | bc)
    echo "Pass Rate: $PASS_RATE%"
fi

echo ""
echo "Detailed Results:"
echo "-----------------"
for result in "${TEST_RESULTS[@]}"; do
    echo "$result"
done 