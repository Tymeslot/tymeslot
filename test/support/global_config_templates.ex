defmodule Tymeslot.Test.GlobalConfigTemplates do
  @moduledoc """
  The `ExUnit.CaseTemplate`s that mutate node-wide application environment, and
  so may only be used by a synchronous test module.

  `Application.put_env/3` is global. A template whose `setup` calls it changes
  the value for **every** test running at that moment, not just the ones using
  the template, so an `async: true` module built on one silently reconfigures
  its neighbours for as long as it runs.

  This list is the source of truth for `CredoChecks.TestGlobalConfigRequiresSync`,
  which cannot see it any other way: Credo analyses one file at a time, so a test
  module that inherits the mutation through `use` looks inert in its own source.
  That is exactly how the fault reached the suite — `ClientConfigTest` was
  written `async: true`, took the mocked HTTP client away from two unrelated
  async modules, and failed them somewhere else entirely.

  ## Adding a template

  Add it here when its `setup` (or anything it calls) writes application env.
  Prefer not needing to: a template that configures its subject through the
  process rather than the node imposes nothing on its users and belongs
  nowhere near this list.
  """

  @templates [
    Tymeslot.HttpTransportCase,
    Tymeslot.ExchangeCase
  ]

  @doc """
  The case templates that force `async: false` on any module using them.
  """
  @spec all() :: [module()]
  def all, do: @templates
end
