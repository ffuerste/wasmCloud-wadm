defmodule Wadm.Deployments.DeploymentMonitor do
  @doc """
  One of these processes should be running to observe and reconcile
  an appspec+version instance.

  This is a Horde-managed server and so only one of these will be running within
  the horde cluster at any given time, and Horde can relocate this to any cluster
  member as it sees fit. Make sure you only ever provision this with the start_deployment_monitor
  function.

  Process Drift
  When a node in a wadm cluster shuts down (intentionally or otherwise), this process
  will be re-started on a new target node _without saving state_. An instant later, that
  same process will try and reconstitute its state from cache.
  """
  use GenServer
  require Logger

  defmodule State do
    defstruct [:spec, :lattice_id]
  end

  @spec start_link(Map.t()) :: GenServer.on_start()
  def start_link(%{app_spec: app_spec, lattice_id: lattice_id} = opts) do
    case GenServer.start_link(__MODULE__, opts, name: via_tuple(app_spec.name, lattice_id)) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("Already running deployment monitor at #{inspect(pid)}")
        :ignore

      other ->
        other
    end
  end

  @impl true
  def init(opts) do
    Logger.debug(
      "Starting Deployment Monitor for deployment #{opts.app_spec.name} v#{opts.app_spec.version}"
    )

    {:ok,
     %State{
       spec: opts.app_spec,
       lattice_id: opts.lattice_id
     }, {:continue, :ensure_lattice_supervisor}}
  end

  @impl true
  def handle_continue(:ensure_lattice_supervisor, state) do
    # Make sure that there's a lattice supervisor running
    {:ok, _pid} = Wadm.LatticeSupervisor.start_lattice_supervisor(state.lattice_id)

    {:noreply, state}
  end

  @spec start_deployment_monitor(AppSpec.t(), String.t()) :: {:error, any} | {:ok, pid()}
  def start_deployment_monitor(app_spec, lattice_id) do
    opts = %{
      app_spec: app_spec,
      lattice_id: lattice_id
    }

    pid = get_process(opts.app_spec.name, opts.lattice_id)

    if pid == nil do
      Horde.DynamicSupervisor.start_child(
        Wadm.HordeSupervisor,
        {Wadm.Deployments.DeploymentMonitor, opts}
      )
    else
      {:ok, pid}
    end
  end

  # Within a libcluster-formed BEAM cluster, each deployment manager is
  # uniquely identified by its spec name and the lattice in which it's
  # running
  def via_tuple(spec_name, lattice_id),
    do: {:via, Horde.Registry, {Wadm.HordeRegistry, "depmon_#{spec_name}_#{lattice_id}"}}

  def get_process(spec_name, lattice_id) when is_binary(lattice_id) do
    case Horde.Registry.lookup(Wadm.HordeRegistry, "depmon_#{spec_name}_#{lattice_id}") do
      [{pid, _val}] -> pid
      [] -> nil
    end
  end
end