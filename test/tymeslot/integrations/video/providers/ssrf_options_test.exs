defmodule Tymeslot.Integrations.Video.Providers.SsrfOptionsTest do
  # Not async: these tests change the application config the guard reads.
  use ExUnit.Case, async: false

  @moduletag :integrations
  @moduletag :security

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Integrations.Video.Providers.SsrfOptions

  test "always turns the guard on" do
    assert Keyword.fetch!(SsrfOptions.request_options(), :ssrf_protect) == true
  end

  test "permits private hosts when the video opt-out is on" do
    with_config(:tymeslot,
      allow_private_ips_for_video: true,
      allow_private_ips_for_calendar: false
    )

    assert Keyword.fetch!(SsrfOptions.request_options(), :ssrf_allow_private) == true
  end

  test "permits private hosts when only the older calendar opt-out is on" do
    with_config(:tymeslot,
      allow_private_ips_for_video: false,
      allow_private_ips_for_calendar: true
    )

    assert Keyword.fetch!(SsrfOptions.request_options(), :ssrf_allow_private) == true
  end

  test "refuses private hosts while both opt-outs are off" do
    with_config(:tymeslot,
      allow_private_ips_for_video: false,
      allow_private_ips_for_calendar: false
    )

    assert Keyword.fetch!(SsrfOptions.request_options(), :ssrf_allow_private) == false
  end
end
