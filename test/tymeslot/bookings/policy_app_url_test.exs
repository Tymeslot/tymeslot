defmodule Tymeslot.Bookings.PolicyAppUrlTest do
  @moduledoc """
  `Policy.app_url/0` is the base every booking link, RSVP link and email link
  is built on. It is pinned to the address the endpoint is configured to serve
  on rather than compared against `Endpoint.url/0`, which is the very call it
  makes and so can never disagree with it.
  """

  use ExUnit.Case, async: true

  @moduletag :bookings

  alias Tymeslot.Bookings.Policy

  # config/test.exs serves the endpoint on TEST_PORT, defaulting to 4002.
  @app_url "http://localhost:#{System.get_env("TEST_PORT") || "4002"}"

  describe "app_url/0" do
    test "is the configured scheme, host and port, with no trailing slash" do
      assert Policy.app_url() == @app_url
    end
  end
end
