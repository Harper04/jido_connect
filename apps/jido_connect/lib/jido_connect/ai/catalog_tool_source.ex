defmodule Jido.Connect.AI.CatalogToolSource do
  @moduledoc """
  Projects one reviewed Connect catalog pack as dynamic Jido AI tools.

  Build the source through `new/2`. The source stores portable tool definitions
  and reviewed fingerprints in the Jido AI request. At execution time, it
  rebuilds the reviewed catalog and rejects a tool whose contract changed.

  Credentials are not part of the source configuration. Pass the current
  `Jido.Connect.Context` and `Jido.Connect.CredentialLease` in the Jido Action
  context when the Agent runs.
  """

  @behaviour Jido.AI.ToolSource

  alias Jido.Connect.Catalog
  alias Jido.Connect.Catalog.{Item, Pack}
  alias Jido.Connect.Error

  @type source_spec :: Jido.AI.ToolSource.spec()

  @doc "Builds a portable Jido AI source for exact integrations and one reviewed pack."
  @spec new(module() | [module()], Pack.t() | map()) ::
          {:ok, source_spec()} | {:error, Error.error()}
  def new(integration_modules, pack) do
    modules = List.wrap(integration_modules)

    with {:ok, pack} <- Pack.resolve_exact(pack),
         {:ok, items} <- Catalog.reviewed_items(modules, pack),
         :ok <- validate_ai_safe_items(items),
         {:ok, tools} <- snapshots(items) do
      {:ok,
       {__MODULE__,
        %{
          modules: modules,
          pack: Catalog.to_map(pack),
          tools: tools
        }}}
    end
  end

  @impl Jido.AI.ToolSource
  def list_tools(%{tools: tools}, _context) when is_list(tools) do
    {:ok, Enum.map(tools, &tool_definition/1)}
  end

  def list_tools(config, _context) do
    {:error,
     Error.validation("Invalid catalog tool source configuration",
       reason: :invalid_catalog_tool_source,
       subject: config
     )}
  end

  @impl Jido.AI.ToolSource
  def run_tool(
        %{name: name, arguments: arguments},
        %{modules: modules, pack: pack, tools: tools},
        context
      )
      when is_binary(name) and is_map(arguments) and is_list(modules) and is_list(tools) and
             is_map(context) do
    with {:ok, snapshot} <- find_snapshot(tools, name),
         {:ok, items} <- Catalog.reviewed_items(modules, pack),
         {:ok, item} <- find_current_item(items, snapshot),
         :ok <- verify_fingerprint(snapshot, item),
         :ok <- verify_action_module(item) do
      apply(item.module, :run, [arguments, context])
    end
  end

  def run_tool(call, _config, _context) do
    {:error,
     Error.validation("Invalid catalog tool call",
       reason: :invalid_catalog_tool_call,
       subject: call
     )}
  end

  defp snapshots(items) do
    with {:ok, snapshots} <- build_snapshots(items),
         :ok <- validate_unique_names(snapshots) do
      {:ok, snapshots}
    end
  end

  defp validate_ai_safe_items(items) do
    case Enum.find(items, &(&1.risk not in [:read, :metadata])) do
      nil ->
        :ok

      item ->
        {:error,
         Error.validation(
           "Catalog mutation tools require the Jido Connect prepare and commit authorization flow",
           reason: :catalog_mutation_tool_not_enabled,
           subject: item.ref,
           details: %{risk: item.risk, confirmation: item.confirmation}
         )}
    end
  end

  defp build_snapshots(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, snapshots} ->
      case snapshot(item) do
        {:ok, snapshot} -> {:cont, {:ok, [snapshot | snapshots]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      {:error, _error} = error -> error
    end
  end

  defp snapshot(%Item{} = item) do
    with :ok <- verify_action_module(item),
         name when is_binary(name) <- item.module.name(),
         fingerprint when is_binary(fingerprint) <- item.reviewed_fingerprint do
      {:ok,
       %{
         ref: item.ref,
         name: name,
         description: item.description || item.label,
         parameter_schema: item.input_json_schema,
         strict: item.strict?,
         schema_digest: item.schema_digest,
         reviewed_fingerprint: fingerprint
       }}
    else
      _other ->
        {:error,
         Error.validation("Catalog item cannot become a Jido AI tool",
           reason: :invalid_catalog_tool,
           subject: item.ref
         )}
    end
  end

  defp tool_definition(snapshot) do
    %{
      name: snapshot.name,
      description: snapshot.description,
      parameter_schema: snapshot.parameter_schema,
      strict: snapshot.strict
    }
  end

  defp validate_unique_names(snapshots) do
    duplicates =
      snapshots
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if duplicates == [] do
      :ok
    else
      {:error,
       Error.validation("Catalog tool names must be unique",
         reason: :duplicate_catalog_tool_names,
         details: %{names: duplicates}
       )}
    end
  end

  defp find_snapshot(tools, name) do
    case Enum.find(tools, &(&1.name == name)) do
      nil ->
        {:error,
         Error.validation("Unknown catalog tool",
           reason: :unknown_tool,
           subject: name
         )}

      snapshot ->
        {:ok, snapshot}
    end
  end

  defp find_current_item(items, snapshot) do
    case Enum.find(items, &(&1.ref == snapshot.ref)) do
      nil ->
        {:error,
         Error.validation("Reviewed catalog tool is no longer available",
           reason: :reviewed_tool_missing,
           subject: snapshot.ref
         )}

      item ->
        {:ok, item}
    end
  end

  defp verify_fingerprint(snapshot, item) do
    if snapshot.reviewed_fingerprint == item.reviewed_fingerprint do
      :ok
    else
      {:error,
       Error.validation("Reviewed catalog tool changed",
         reason: :reviewed_tool_changed,
         subject: snapshot.ref,
         details: %{
           expected_fingerprint: snapshot.reviewed_fingerprint,
           actual_fingerprint: item.reviewed_fingerprint
         }
       )}
    end
  end

  defp verify_action_module(%Item{module: module, ref: ref}) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :name, 0),
         true <- function_exported?(module, :run, 2) do
      :ok
    else
      _other -> invalid_action_module(ref, module)
    end
  end

  defp verify_action_module(%Item{module: module, ref: ref}),
    do: invalid_action_module(ref, module)

  defp invalid_action_module(ref, module) do
    {:error,
     Error.validation("Catalog item has no generated Jido Action",
       reason: :catalog_action_module_required,
       subject: ref,
       details: %{module: module}
     )}
  end
end
