defmodule TymeslotWeb.Plugs.SecurityHeaders.HstsTest do
  use ExUnit.Case, async: true

  @moduletag :plugs
  @moduletag :security
  @moduletag :unit

  alias TymeslotWeb.Plugs.SecurityHeaders.Hsts

  doctest Hsts

  describe "header/1" do
    test "an absent config binds the sending host only" do
      # The default Core ships to self-hosters. `max-age` is still sent (the
      # header must be present and host-scoped, not absent), but neither
      # directive that reaches other subdomains is asserted.
      assert Hsts.header([]) == "max-age=31536000"
    end

    test "includeSubDomains is added only when opted in" do
      assert Hsts.header(include_subdomains: true) == "max-age=31536000; includeSubDomains"
      assert Hsts.header(include_subdomains: false) == "max-age=31536000"
    end

    test "preload is added only when opted in" do
      assert Hsts.header(preload: true) == "max-age=31536000; preload"
      assert Hsts.header(preload: false) == "max-age=31536000"
    end

    test "both directives together render in the conventional order" do
      assert Hsts.header(include_subdomains: true, preload: true) ==
               "max-age=31536000; includeSubDomains; preload"
    end

    test "max_age is configurable and always leads" do
      assert Hsts.header(max_age: 600) == "max-age=600"

      assert Hsts.header(max_age: 63_072_000, include_subdomains: true) ==
               "max-age=63072000; includeSubDomains"
    end
  end
end
