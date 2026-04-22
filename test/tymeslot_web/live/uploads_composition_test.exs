defmodule TymeslotWeb.UploadsCompositionTest do
  @moduledoc """
  Composition coverage for the LiveView upload pipeline.

  Size limit + extension allow-list are enforced by Phoenix LiveView at the
  framework level via `allow_upload/3`. The server-side guards in
  `Tymeslot.Profiles.Avatars.validate_upload/1` and
  `Tymeslot.Utils.MediaValidator.valid_image?/1` are the defence-in-depth
  layer: they protect the disk/DB even if the framework allow-list is ever
  reconfigured. These tests pin both layers at their user-observable
  surface — an error rendered into the page and no mutation to the
  persisted profile.

    * size boundary (10 MB + 1 byte) — rejected at the framework layer
    * wrong MIME / extension (SVG) — rejected at the framework layer
    * zero-byte content past the framework layer — rejected by
      `MediaValidator` (empty binary has no valid image magic bytes)
    * path-traversal `client_name` past the framework layer — rejected
      by `Avatars.validate_file_name/1`

  Not covered here:

    * concurrent progress replacement — a Phoenix LiveView framework
      guarantee (`max_entries: 1` cancels a second in-flight entry); not
      ours to pin.
    * video transcoder failure surface — lives in ThemeUploadHelper and
      is better covered at the helper-unit layer where Oban / transcoder
      stubs can be wired cleanly.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :profiles
  @moduletag :live
  @moduletag :security

  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Profiles.Avatars
  alias Tymeslot.Repo
  alias Tymeslot.Utils.MediaValidator

  setup :setup_dashboard_user

  # Valid PNG magic-bytes header + minimal IHDR.
  @valid_png_header <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0,
                      0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 0x90, 0x77, 0x53, 0xDE>>

  describe "avatar upload — framework-layer rejections" do
    test "file larger than max_file_size is rejected and profile is unchanged", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      # max_file_size is 10_000_000. Pad the header with a single byte over
      # the cap so LiveView's framework-level size check fails.
      padding_size = Avatars.max_file_size() + 1 - byte_size(@valid_png_header)
      oversized = @valid_png_header <> :binary.copy(<<0>>, padding_size)

      upload = %{
        last_modified: System.system_time(:millisecond),
        name: "avatar.png",
        content: oversized,
        type: "image/png"
      }

      # `render_upload/2` returns `{:error, ...}` when the client-side
      # preflight rejects the entry. The humanised error appears in the
      # rendered view once the upload's `errors` list is populated.
      view
      |> file_input("#avatar-upload-form", :avatar, [upload])
      |> render_upload("avatar.png")

      assert render(view) =~ "Too large"

      # Defence-in-depth: the persisted avatar value must not have changed.
      assert Repo.reload!(profile).avatar == profile.avatar
    end

    test "SVG upload is rejected by the allow-list and profile is unchanged", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      upload = %{
        last_modified: System.system_time(:millisecond),
        name: "avatar.svg",
        content: ~s(<svg xmlns="http://www.w3.org/2000/svg"></svg>),
        type: "image/svg+xml"
      }

      view
      |> file_input("#avatar-upload-form", :avatar, [upload])
      |> render_upload("avatar.svg")

      assert render(view) =~ "Not accepted"
      assert Repo.reload!(profile).avatar == profile.avatar
    end
  end

  describe "media validator — server-side defence in depth" do
    # `MediaValidator.valid_image?/1` is the last line of defence before
    # a file is copied into `priv/uploads`. Phoenix LiveView's test
    # upload client can't chunk a 0-byte entry (division by zero in its
    # progress accounting), so zero-byte and garbage-content rejection is
    # pinned here at the validator level where the guarantee actually
    # lives.

    test "rejects an empty binary" do
      refute MediaValidator.valid_image?(<<>>)
    end

    test "rejects a binary that claims the png MIME but has garbage content" do
      refute MediaValidator.valid_image?(:binary.copy(<<0>>, 4_096))
    end

    test "accepts a minimal valid PNG" do
      assert MediaValidator.valid_image?(@valid_png_header)
    end

    test "rejects non-binary input" do
      refute MediaValidator.valid_image?(nil)
      refute MediaValidator.valid_image?(:not_a_binary)
    end
  end

  describe "avatars.validate_file_name/1" do
    # The LiveView upload form is configured with `accept:` restricted to
    # image extensions, so the framework layer blocks a raw `../etc/passwd`
    # client_name before it ever reaches the consume callback. The
    # server-side `Avatars.validate_file_name/1` guard is the defence-in-
    # depth layer — a future change that loosens `accept:` or that invokes
    # the consume path from a non-LV entrypoint must still refuse these
    # names. These unit tests pin that contract directly.

    test "rejects a filename containing ../" do
      assert {:error, "Invalid file name"} =
               Avatars.validate_file_name(%{"client_name" => "../etc/passwd.png"})
    end

    test "rejects a filename containing a null byte" do
      assert {:error, "Invalid file name"} =
               Avatars.validate_file_name(%{"client_name" => "ok\0hidden.png"})
    end

    test "rejects a filename with a windows-style backslash traversal" do
      assert {:error, "Invalid file name"} =
               Avatars.validate_file_name(%{"client_name" => "..\\win.png"})
    end

    test "rejects a filename over 255 characters even if it contains only safe chars" do
      long_name = String.duplicate("a", 260) <> ".png"

      assert {:error, "File name too long"} =
               Avatars.validate_file_name(%{"client_name" => long_name})
    end

    test "accepts a legitimate unicode filename" do
      assert :ok = Avatars.validate_file_name(%{"client_name" => "café.png"})
    end
  end
end
