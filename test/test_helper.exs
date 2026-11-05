ExUnit.start(exclude: [:dual_node, :cluster])

# ICE-lite host advertise is required; pin loopback for unit tests.
Application.put_env(:xylon, :ice, advertised_ip: {127, 0, 0, 1})
