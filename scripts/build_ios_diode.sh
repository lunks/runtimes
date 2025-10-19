#!/bin/bash
export OTP_TAG=${OTP_TAG:-OTP-28.1}
export ELIXIR_VERSION=${ELIXIR_VERSION:-1.19.0}
export OTP_SOURCE=${OTP_SOURCE:-https://github.com/erlang/otp}
mix package.ios.runtime with_diode_nifs
