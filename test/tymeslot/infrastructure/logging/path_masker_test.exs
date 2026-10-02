defmodule Tymeslot.Infrastructure.Logging.PathMaskerTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  alias Tymeslot.Infrastructure.Logging.PathMasker

  doctest PathMasker

  @uid "0b7e1f3a-4c1d-4a8e-9f3b-2d6c8e1a5b7c"
  @token "Xk3v9Qm2Lp8Rt5Wz1Yb7Nc4Hd6Fg0Js2AeKq-_Uv"

  # Shared with the browser analytics scrubber's tests
  # (`assets/js/__tests__/analytics.test.js`): both maskers must produce the
  # same output for every case, so they cannot drift apart again.
  @fixture_path Path.expand("../../../support/fixtures/path_masking.json", __DIR__)
  @external_resource @fixture_path
  @shared_cases @fixture_path |> File.read!() |> JSON.decode!()

  test "the shared fixture has cases to check" do
    assert length(@shared_cases) > 10
  end

  for %{"case" => name, "path" => path, "masked" => masked} <- @shared_cases do
    test "agrees with the analytics scrubber: #{name}" do
      assert PathMasker.mask(unquote(path)) == unquote(masked)
    end
  end

  test "masks the meeting uid in a meeting management path" do
    assert PathMasker.mask("/jane/meeting/#{@uid}/cancel") == "/jane/meeting/:id/cancel"
  end

  test "masks a link token" do
    assert PathMasker.mask("/meeting-request/#{@token}") == "/meeting-request/:id"
    assert PathMasker.mask("/jane/poll/#{@token}") == "/jane/poll/:id"
  end

  test "leaves an ordinary path unchanged" do
    assert PathMasker.mask("/dashboard/settings") == "/dashboard/settings"
    assert PathMasker.mask("/jane/30min") == "/jane/30min"
  end

  test "masks the path of a full URL and keeps its query and fragment" do
    assert PathMasker.mask("https://book.example.com/jane/meeting/#{@uid}/reschedule?tab=1#top") ==
             "https://book.example.com/jane/meeting/:id/reschedule?tab=1#top"
  end

  test "returns anything that is not a string unchanged" do
    assert PathMasker.mask(nil) == nil
  end
end
