defmodule Tymeslot.Test.UploadRoot do
  @moduledoc """
  Gives a test an upload root of its own for the rest of the test.

  The endpoint serves `/uploads` from the root it finds on the first request
  that reaches it and keeps those options for the life of the node
  (`TymeslotWeb.Endpoint`, `:persistent_term`). A test that only sets
  `:upload_directory` therefore leaves the endpoint serving its own
  temporary root to every later test, which then answers 404 for files
  that exist. `isolate/1` forgets the endpoint's options on the way in and
  on the way out, so `/uploads` follows the root of whichever test is
  running.

  Like every global setting, it is for `async: false` modules only.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Tymeslot.Media.Uploads

  @static_opts_key {TymeslotWeb.Endpoint, :upload_static_opts}

  @doc """
  Points `:upload_directory` at a fresh temporary directory named after
  `prefix`, restores the previous root and deletes the directory when the
  test exits, and returns the new root.
  """
  @spec isolate(String.t()) :: Path.t()
  def isolate(prefix \\ "tymeslot_uploads") do
    root = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    point_at(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  @doc """
  Points `:upload_directory` at `root`, a directory the test owns (an
  ExUnit `tmp_dir`, say), until the test exits, and returns it.
  """
  @spec point_at(Path.t()) :: Path.t()
  def point_at(root) do
    original = Application.get_env(:tymeslot, :upload_directory)

    Application.put_env(:tymeslot, :upload_directory, root)
    forget_endpoint_options()

    on_exit(fn ->
      Application.put_env(:tymeslot, :upload_directory, original)
      forget_endpoint_options()
    end)

    root
  end

  @doc """
  Where a stored relative path (as a customisation's settings hold it)
  lies on disk under the current root, for writing a fixture or checking
  a file directly. Tests of what a visitor gets should fetch
  `/uploads/<path>` instead.
  """
  @spec path(String.t()) :: Path.t()
  def path(relative), do: Path.join(Uploads.root(), relative)

  defp forget_endpoint_options do
    :persistent_term.erase(@static_opts_key)
    :ok
  end
end
