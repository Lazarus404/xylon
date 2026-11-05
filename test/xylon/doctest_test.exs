defmodule Xylon.DoctestTest do
  use ExUnit.Case, async: true

  doctest Xylon.Control.Auth.HMAC
  doctest Xylon.Control.Acl
  doctest Xylon.Control.Dest
  doctest Xylon.Control.Webhooks.Delivery
end
