#!/bin/bash
export OTP_TAG=${OTP_TAG:-OTP-28.1}
export ELIXIR_VERSION=${ELIXIR_VERSION:-1.19.0}
export OTP_SOURCE=${OTP_SOURCE:-https://github.com/erlang/otp}
# Uncomment to use local OTP checkout:
# export OTP_SOURCE=$HOME/projects/otp
mix package.android.runtime with_diode_nifs
