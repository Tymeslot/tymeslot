defmodule TymeslotWeb.Helpers.UploadHandlerTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias Phoenix.LiveView.Socket
  alias Phoenix.LiveView.UploadConfig
  alias Phoenix.LiveView.UploadEntry
  alias TymeslotWeb.Helpers.UploadHandler

  @conf_ref "avatar-conf"

  defp socket_with_entries(entries) do
    %Socket{assigns: %{uploads: %{avatar: %{entries: entries}}, __changed__: %{}}}
  end

  # A socket carrying a real `%UploadConfig{}`, which is what `settle_upload/2`
  # needs to see the config-level errors LiveView keys on the upload rather
  # than on an entry.
  defp socket_with_config(entries, errors) do
    config = %UploadConfig{
      name: :avatar,
      ref: @conf_ref,
      max_entries: 1,
      entries: entries,
      errors: errors,
      entry_refs_to_pids: Map.new(entries, &{&1.ref, :unregistered}),
      entry_refs_to_metas: %{}
    }

    %Socket{assigns: %{uploads: %{avatar: config}, __changed__: %{}}}
  end

  defp entry(ref, opts \\ []) do
    %UploadEntry{
      ref: ref,
      upload_config: :avatar,
      valid?: Keyword.get(opts, :valid?, true),
      done?: Keyword.get(opts, :done?, false),
      preflighted?: Keyword.get(opts, :preflighted?, false)
    }
  end

  describe "settle_upload/2" do
    test "reports :settled once every entry has finished" do
      socket = socket_with_entries([entry("a", done?: true), entry("b", done?: true)])

      assert {_socket, :settled} = UploadHandler.settle_upload(socket, :avatar)
    end

    test "reports :in_progress while a sibling entry is still uploading" do
      # The shape that crashed the onboarding LiveView: the progress callback
      # runs for "a", which is done, while "b" is still in flight. Consuming
      # here raises ArgumentError.
      socket =
        socket_with_entries([
          entry("a", done?: true, preflighted?: true),
          entry("b", done?: false, preflighted?: true)
        ])

      assert {_socket, :in_progress} = UploadHandler.settle_upload(socket, :avatar)
    end

    test "cancels the entry stranded past max_entries so the finished one can be consumed" do
      # The excess entry is `valid?: true` — LiveView reports the breach as a
      # config-level `:too_many_files` — and was never issued an upload token,
      # so it can never become done. Left in place it wedges the upload.
      socket =
        socket_with_config(
          [entry("a", done?: true, preflighted?: true), entry("b")],
          [{@conf_ref, :too_many_files}]
        )

      assert {socket, :settled} = UploadHandler.settle_upload(socket, :avatar)
      assert [%UploadEntry{ref: "a"}] = UploadHandler.upload_entries(socket, :avatar)
    end

    test "leaves an entry still awaiting its preflight alone while the upload has room" do
      # Same shape, no `:too_many_files`: this entry is a fresh selection whose
      # preflight round trip has not landed yet. Cancelling it would drop a
      # real file the user chose.
      socket =
        socket_with_config([entry("a", done?: true, preflighted?: true), entry("b")], [])

      assert {socket, :in_progress} = UploadHandler.settle_upload(socket, :avatar)

      assert [%UploadEntry{ref: "a"}, %UploadEntry{ref: "b"}] =
               UploadHandler.upload_entries(socket, :avatar)
    end

    test "reports :settled when the upload key is not configured on the socket" do
      assert {_socket, :settled} =
               UploadHandler.settle_upload(%Socket{assigns: %{__changed__: %{}}}, :avatar)
    end
  end

  describe "upload_entries/2" do
    test "returns the configured entries" do
      socket = socket_with_entries([entry("a", done?: true)])

      assert [%UploadEntry{ref: "a"}] = UploadHandler.upload_entries(socket, :avatar)
    end

    test "returns [] when no upload is configured for the key" do
      assert UploadHandler.upload_entries(%Socket{assigns: %{__changed__: %{}}}, :avatar) == []
    end
  end
end
