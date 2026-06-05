(() => {
	const CONFIG_LOCALSTORAGE_KEY = "LlamaCppWebui.config";
	const selectedModelStorageKey = "router:selected-model-id";
	const cacheTypes = [
		"",
		"f32",
		"f16",
		"bf16",
		"q8_0",
		"q4_0",
		"q4_1",
		"q5_0",
		"q5_1",
		"iq4_nl",
		"turbo2",
		"turbo3",
		"turbo4"
	];
	const advertisedEndpoints = [
		{ method: "GET", path: "/health" },
		{ method: "GET", path: "/v1/models" },
		{ method: "GET", path: "/models" },
		{ method: "POST", path: "/models/load" },
		{ method: "POST", path: "/models/unload" },
		{ method: "GET", path: "/props?model=..." },
		{ method: "GET", path: "/slots?model=..." },
		{ method: "GET", path: "/tools?model=..." },
		{ method: "POST", path: "/v1/chat/completions" },
		{ method: "POST", path: "/v1/responses" },
		{ method: "POST", path: "/v1/embeddings" },
		{ method: "POST", path: "/v1/rerank" },
		{ method: "POST", path: "/completion" },
		{ method: "POST", path: "/rerank" }
	];
	const state = {
		appConfig: null,
		routerEndpoints: null,
		models: [],
		modelStatuses: {},
		modelStatusDetails: {},
		pendingModelLoads: new Set(),
		runtimeStatus: null,
		runtimeFlags: [],
		runtimes: null,
		runtimeReleases: [],
		runtimeFamily: "llama",
		runtimeLinuxBackend: "cuda13",
		runtimeFetching: false,
		runtimePairPending: new Map(),
		devices: [],
		deviceError: "",
		selectedId: null,
		draft: null,
		dirty: false,
		saving: false,
		loading: false,
		errorText: "",
		statusText: "app.yaml router settings",
		modelFilter: "",
		modelTypeFilter: "",
		rpcExpanded: false,
		endpointsOpen: false,
		downloadOpen: false,
		hfRepo: "",
		hfRevision: "main",
		hfPath: "",
		hfLocation: "mac",
		hfRecursive: true,
		hfEntries: [],
		hfCheckedPaths: new Set(),
		downloads: [],
		downloadStats: new Map(),
		downloadTimer: null,
		modelCopies: [],
		modelCopyStats: new Map(),
		modelCopyTimer: null,
		selectedDeviceName: "",
		dragDeviceIndex: null
	};
	let modelStatusTimer = null;
	let runtimeInstallPollTimer = null;
	let runtimeInstallPollStartedAt = 0;

	const el = {
		statusText: document.getElementById("statusText"),
		errorBanner: document.getElementById("errorBanner"),
		authPanel: document.getElementById("authPanel"),
		authApiKeyInput: document.getElementById("authApiKeyInput"),
		authSaveButton: document.getElementById("authSaveButton"),
		refreshAllButton: document.getElementById("refreshAllButton"),
		serverHostInput: document.getElementById("serverHostInput"),
		serverPortInput: document.getElementById("serverPortInput"),
		serverApiKeysInput: document.getElementById("serverApiKeysInput"),
		serverAllowInsecureSelect: document.getElementById("serverAllowInsecureSelect"),
		serverResidencyModeSelect: document.getElementById("serverResidencyModeSelect"),
		serverMaxActiveInput: document.getElementById("serverMaxActiveInput"),
		macApiEndpoint: document.getElementById("macApiEndpoint"),
		vmApiEndpoint: document.getElementById("vmApiEndpoint"),
		saveServerButton: document.getElementById("saveServerButton"),
		checkRuntimeButton: document.getElementById("checkRuntimeButton"),
		runtimeSummary: document.getElementById("runtimeSummary"),
		runtimeInstallSummary: document.getElementById("runtimeInstallSummary"),
		runtimeCards: document.getElementById("runtimeCards"),
		runtimeFamilySelect: document.getElementById("runtimeFamilySelect"),
		runtimeReleaseSelect: document.getElementById("runtimeReleaseSelect"),
		runtimeLinuxBackendSelect: document.getElementById("runtimeLinuxBackendSelect"),
		fetchRuntimeButton: document.getElementById("fetchRuntimeButton"),
		pairedRuntimeSelect: document.getElementById("pairedRuntimeSelect"),
		usePairRuntimeButton: document.getElementById("usePairRuntimeButton"),
		retryPairRuntimeButton: document.getElementById("retryPairRuntimeButton"),
		deletePairRuntimeButton: document.getElementById("deletePairRuntimeButton"),
		endpointsButton: document.getElementById("endpointsButton"),
		endpointsPopover: document.getElementById("endpointsPopover"),
		toggleRPCButton: document.getElementById("toggleRPCButton"),
		rpcEditor: document.getElementById("rpcEditor"),
		rpcRows: document.getElementById("rpcRows"),
		addRPCButton: document.getElementById("addRPCButton"),
		saveRPCButton: document.getElementById("saveRPCButton"),
		refreshDevicesButton: document.getElementById("refreshDevicesButton"),
		deviceSummary: document.getElementById("deviceSummary"),
		deviceErrorBox: document.getElementById("deviceErrorBox"),
		devicesTableBody: document.getElementById("devicesTableBody"),
		modelsCountText: document.getElementById("modelsCountText"),
		modelTypeSelect: document.getElementById("modelTypeSelect"),
		modelFilterInput: document.getElementById("modelFilterInput"),
		refreshModelsButton: document.getElementById("refreshModelsButton"),
		openDownloadButton: document.getElementById("openDownloadButton"),
		modelsList: document.getElementById("modelsList"),
		modelEmptyState: document.getElementById("modelEmptyState"),
		modelDetail: document.getElementById("modelDetail"),
		modelTitle: document.getElementById("modelTitle"),
		modelSubline: document.getElementById("modelSubline"),
		modelTransferPanel: document.getElementById("modelTransferPanel"),
		modelForm: document.getElementById("modelForm"),
		loadModelButton: document.getElementById("loadModelButton"),
		unloadModelButton: document.getElementById("unloadModelButton"),
		saveModelButton: document.getElementById("saveModelButton"),
		copyModelHeaderButton: document.getElementById("copyModelHeaderButton"),
		deleteModelButton: document.getElementById("deleteModelButton"),
		downloadModal: document.getElementById("downloadModal"),
		downloadBackdrop: document.getElementById("downloadBackdrop"),
		closeDownloadButton: document.getElementById("closeDownloadButton"),
		hfRepoInput: document.getElementById("hfRepoInput"),
		hfRevisionInput: document.getElementById("hfRevisionInput"),
		hfPathInput: document.getElementById("hfPathInput"),
		hfLocationSelect: document.getElementById("hfLocationSelect"),
		hfRecursiveInput: document.getElementById("hfRecursiveInput"),
		listHFButton: document.getElementById("listHFButton"),
		downloadHFButton: document.getElementById("downloadHFButton"),
		downloadsList: document.getElementById("downloadsList"),
		hfEntriesCount: document.getElementById("hfEntriesCount"),
		hfEntriesList: document.getElementById("hfEntriesList")
	};

	function escapeHTML(value) {
		return String(value ?? "")
			.replaceAll("&", "&amp;")
			.replaceAll("<", "&lt;")
			.replaceAll(">", "&gt;")
			.replaceAll('"', "&quot;")
			.replaceAll("'", "&#39;");
	}

	function clone(value) {
		return JSON.parse(JSON.stringify(value));
	}

	function csv(value) {
		return String(value ?? "")
			.split(",")
			.map((part) => part.trim())
			.filter(Boolean);
	}

	function lines(value) {
		return String(value ?? "")
			.split(/\n+/)
			.map((line) => line.trim())
			.filter(Boolean);
	}

	function normalizeAppConfig(config) {
		const next = config ?? {};
		next.server = {
			host: "127.0.0.1",
			port: 9292,
			apiKeys: [],
			allowInsecureRemote: false,
			...(next.server ?? {})
		};
		next.runtime = {
			llamaServerPath: "./llama-server",
			releaseRepo: "custom",
			updateChannel: "custom",
			...(next.runtime ?? {})
		};
		next.rpcServers = next.rpcServers ?? [];
		next.models = next.models ?? {};
		return next;
	}

	function normalizeRouterEndpoints(endpoints, config = state.appConfig) {
		const port = Number(config?.server?.port || 9292);
		return {
			macBaseURL: `http://127.0.0.1:${port}`,
			vmBaseURL: `http://172.29.253.1:${port}`,
			...(endpoints ?? {})
		};
	}

	function setStatus(text) {
		state.statusText = text || "app.yaml router settings";
		if (el.statusText) el.statusText.textContent = state.statusText;
	}

	function setError(error) {
		state.errorText = error ? String(error) : "";
		el.errorBanner.textContent = state.errorText;
		el.errorBanner.classList.toggle("hidden", !state.errorText);
		if (state.errorText) setStatus(state.errorText);
	}

	function getStoredApiKey() {
		try {
			const config = JSON.parse(localStorage.getItem(CONFIG_LOCALSTORAGE_KEY) || "{}");
			return String(config.apiKey ?? "").trim();
		} catch {
			return "";
		}
	}

	function setStoredApiKey(apiKey) {
		const trimmed = String(apiKey ?? "").trim();
		let config = {};
		try {
			config = JSON.parse(localStorage.getItem(CONFIG_LOCALSTORAGE_KEY) || "{}");
		} catch {
			config = {};
		}
		config.apiKey = trimmed;
		localStorage.setItem(CONFIG_LOCALSTORAGE_KEY, JSON.stringify(config));
	}

	function authHeaders() {
		const apiKey = getStoredApiKey();
		return apiKey ? { Authorization: `Bearer ${apiKey}` } : {};
	}

	async function parseError(response) {
		try {
			const data = await response.json();
			return data?.error?.message || data?.message || response.statusText;
		} catch {
			return response.statusText || `HTTP ${response.status}`;
		}
	}

	async function apiFetch(path, options = {}) {
		const headers = {
			"Content-Type": "application/json",
			...authHeaders(),
			...(options.headers ?? {})
		};
		const response = await fetch(path, { ...options, headers });
		if (!response.ok) {
			const message = await parseError(response);
			if (response.status === 401 || response.status === 403) {
				el.authPanel.classList.remove("hidden");
			}
			throw new Error(message);
		}
		if (response.status === 204) return null;
		return response.json();
	}

	function formatBytes(bytes) {
		if (!Number.isFinite(Number(bytes)) || Number(bytes) <= 0) return "";
		const units = ["B", "KiB", "MiB", "GiB", "TiB"];
		let value = Number(bytes);
		let index = 0;
		while (value >= 1024 && index < units.length - 1) {
			value /= 1024;
			index += 1;
		}
		return `${value.toFixed(index ? 1 : 0)} ${units[index]}`;
	}

	function formatBytesRequired(bytes) {
		return formatBytes(bytes) || "0 B";
	}

	function sortModelList(items) {
		return [...items].sort((a, b) => {
			if (!!a.available !== !!b.available) return a.available ? -1 : 1;
			return String(a.name || a.id).localeCompare(String(b.name || b.id));
		});
	}

	function modelStatus(model) {
		const status = state.modelStatuses[model.id] ?? (model.available ? "unloaded" : "failed");
		if (state.pendingModelLoads.has(model.id) && status !== "loaded" && status !== "failed") return "loading";
		return status;
	}

	function modelStatusInfo(model) {
		const info = state.modelStatusDetails[model.id] ?? { value: modelStatus(model), args: [] };
		if (state.pendingModelLoads.has(model.id) && info.value !== "loaded" && info.value !== "failed") {
			return { ...info, value: "loading" };
		}
		return info;
	}

	function statusClass(status) {
		if (status === "loaded") return "status-loaded";
		if (status === "loading") return "status-loading";
		if (status === "failed") return "status-failed";
		return "";
	}

	function firstMetadataNumber(model, needles) {
		if (!model?.metadata) return null;
		for (const [key, value] of Object.entries(model.metadata)) {
			const lower = key.toLowerCase();
			if (!needles.some((needle) => lower === needle || lower.endsWith(`.${needle}`))) continue;
			const parsed = Number(value);
			if (Number.isFinite(parsed) && parsed > 0) return parsed;
		}
		return null;
	}

	function modelContextLength(model) {
		return firstMetadataNumber(model, ["context_length", "n_ctx_train", "max_context"]);
	}

	function modelLayerCount(model) {
		return firstMetadataNumber(model, ["block_count", "layer_count", "n_layer"]);
	}

	function inferModelTask(model) {
		const haystack = [
			model?.metadata?.task || model?.metadata?.["general.name"],
			model?.id,
			model?.name,
			model?.source,
			model?.modelPath
		]
			.filter(Boolean)
			.join(" ")
			.toLowerCase();
		if (haystack.includes("rerank") || haystack.includes("reranker")) return "rerank";
		if (haystack.includes("embed") || haystack.includes("e5") || haystack.includes("gte")) {
			return "embedding";
		}
		return "";
	}

	function modelArchitecture(model) {
		return String(model?.metadata?.["general.architecture"] || "").trim();
	}

	function modelKind(model) {
		const task = inferModelTask(model);
		if (task === "rerank") return "rerank";
		if (task === "embedding") return "embedding";
		if (model?.mmprojPath) return "vision";
		const haystack = [model?.id, model?.name, model?.source, modelArchitecture(model)]
			.filter(Boolean)
			.join(" ")
			.toLowerCase();
		if (haystack.includes("instruct") || haystack.includes("chat") || haystack.includes("it")) return "chat";
		return "text";
	}

	function modelKindLabel(kind) {
		return {
			chat: "Chat",
			vision: "Vision",
			embedding: "Embedding",
			rerank: "Rerank",
			text: "Text"
		}[kind] || "Model";
	}

	function modelLocation(model) {
		const raw = String(model?.location || "").toLowerCase();
		if (raw === "vm" || String(model?.modelPath || "").startsWith("/home/vegpu/")) return "vm";
		return "mac";
	}

	function modelLocationLabel(model) {
		return modelLocation(model) === "vm" ? "VM" : "MAC";
	}

	function modelPathDisplay(model) {
		return `${modelLocationLabel(model)} ${model?.modelPath || ""}`;
	}

	function copyModelLabel(model) {
		if (!["huggingface", "lmstudio"].includes(String(model?.provider || "").toLowerCase())) return "";
		return modelLocation(model) === "vm" ? "Copy to Mac" : "Copy to VM";
	}

	function copyModelUnavailableReason(model) {
		const provider = String(model?.provider || "").toLowerCase();
		if (!model?.modelPath) return "No model path to copy";
		if (!["huggingface", "lmstudio"].includes(provider)) return "Copy supports Hugging Face and LM Studio models only";
		return "";
	}

	function isHiddenModel(model) {
		const reason = String(model?.missingReason || "").toLowerCase();
		const arch = modelArchitecture(model).toLowerCase();
		const path = String(model?.modelPath || "");
		return (
			reason.includes("unsupported gguf architecture") ||
			reason.includes("non-primary gguf split shard") ||
			/-(?!00001)[0-9]{5}-of-[0-9]{5}\.gguf$/i.test(path) ||
			["wan", "flux", "sd", "stable-diffusion", "stable_diffusion", "diffusion", "sortformer", "voxtral_realtime"].includes(arch)
		);
	}

	function usableDevices() {
		return state.devices.filter((device) => {
			const backend = String(device.backend ?? "").toLowerCase();
			const name = String(device.name ?? "").toLowerCase();
			if (device.remote) return true;
			return !(
				backend === "cpu" ||
				backend === "blas" ||
				name.startsWith("blas") ||
				((device.totalMiB ?? 0) <= 0 && backend === "unknown")
			);
		});
	}

	function deviceBackend(device) {
		return String(device?.backend || device?.name || "").toLowerCase();
	}

	function deviceName(device) {
		return String(device?.name || "").trim();
	}

	function deviceLocation(device) {
		return String(device?.location || "").toLowerCase();
	}

	function isMacDevice(device) {
		const backend = deviceBackend(device);
		const name = deviceName(device).toLowerCase();
		const location = deviceLocation(device);
		return backend.startsWith("mtl") || backend.startsWith("metal") || name.startsWith("mtl") || location.includes("macos");
	}

	function isRPCDevice(device) {
		const backend = deviceBackend(device);
		const name = deviceName(device).toLowerCase();
		return backend.startsWith("rpc") || name.startsWith("rpc");
	}

	function isVMAcceleratorDevice(device) {
		const backend = deviceBackend(device);
		const name = deviceName(device).toLowerCase();
		return (
			(backend.startsWith("cuda") ||
				backend.startsWith("vulkan") ||
				backend.startsWith("vk") ||
				backend.startsWith("hip") ||
				backend.startsWith("sycl") ||
				backend.startsWith("opencl") ||
				name.startsWith("cuda") ||
				name.startsWith("vulkan") ||
				name.startsWith("vk") ||
				name.startsWith("hip") ||
				name.startsWith("sycl") ||
				name.startsWith("opencl")) &&
			!isMacDevice(device)
		);
	}

	function selectionKeys(device) {
		const keys = new Set();
		const name = deviceName(device);
		if (name) keys.add(name.toUpperCase());
		if (device?.sourceName) keys.add(String(device.sourceName).toUpperCase());
		if (device?.uuid) keys.add(`UUID:${String(device.uuid).toLowerCase()}`);
		if (device?.pciAddress) keys.add(`PCI:${String(device.pciAddress).toLowerCase().replace(/^00000000:/, "0000:")}`);
		const rpc = /^RPC(\d+)$/i.exec(name);
		if (rpc) {
			for (const prefix of ["CUDA", "VULKAN", "VK", "HIP", "SYCL", "OPENCL"]) keys.add(`${prefix}${rpc[1]}`);
		}
		const accelerator = /^(CUDA|VULKAN|VK|HIP|SYCL|OPENCL)(\d+)$/i.exec(name);
		if (accelerator) keys.add(`RPC${accelerator[2]}`.toUpperCase());
		return keys;
	}

	function selectedDeviceNames() {
		const selected = new Set();
		for (const device of launch().devices ?? []) {
			for (const key of selectionKeys(device)) selected.add(key);
		}
		return selected;
	}

	function availableDevicesForAdd() {
		const selected = selectedDeviceNames();
		const devices = usableDevices();
		const out = [];
		for (const device of devices) {
			const keys = selectionKeys(device);
			if ([...keys].some((key) => selected.has(key))) continue;
			out.push(device);
		}
		return out;
	}

	function deviceDisplayLabel(device) {
		const location = device.location || (device.remote ? device.endpoint || "RPC" : "local");
		return `${location} - ${device.description || device.label || device.backend || "device"}${
			device.totalMiB ? ` - ${Math.round(device.totalMiB / 1024)} GiB` : ""
		}${device.pciAddress ? ` - ${device.pciAddress}` : ""}`;
	}

	function deviceLabel(name) {
		const device = usableDevices().find((item) => item.name === name);
		if (!device) return name;
		return deviceDisplayLabel(device);
	}

	function isVMInternalRPCDevice(device) {
		const location = String(device?.location ?? "").toLowerCase();
		const endpoint = String(device?.endpoint ?? "");
		return isRPCDevice(device) && (location.includes("vegpu vm") || endpoint.startsWith("172.29.253.100:"));
	}

	function vmDeviceForRPCSelection(device) {
		if (!isRPCDevice(device)) return null;
		const rpcIndex = /^RPC(\d+)$/i.exec(deviceName(device))?.[1] ?? "";
		const candidates = usableDevices().filter(isVMAcceleratorDevice);
		if (device.uuid) {
			const uuid = String(device.uuid).toLowerCase();
			const match = candidates.find((item) => String(item.uuid ?? "").toLowerCase() === uuid);
			if (match) return match;
		}
		if (device.pciAddress) {
			const pci = String(device.pciAddress).toLowerCase().replace(/^00000000:/, "0000:");
			const match = candidates.find(
				(item) => String(item.pciAddress ?? "").toLowerCase().replace(/^00000000:/, "0000:") === pci
			);
			if (match) return match;
		}
		if (rpcIndex) {
			const match = candidates.find((item) => {
				const parsed = /^(cuda|vulkan|vk|hip|sycl|opencl)(\d+)$/i.exec(deviceName(item));
				return parsed?.[2] === rpcIndex;
			});
			if (match) return match;
		}
		if (device.totalMiB) {
			const matches = candidates.filter((item) => item.totalMiB === device.totalMiB);
			if (matches.length === 1) return matches[0];
		}
		return null;
	}

	function mergeSavedDevice(current, saved) {
		const out = { ...(current ?? {}), ...(saved ?? {}) };
		for (const key of ["label", "description", "backend", "location", "endpoint", "pciAddress", "uuid"]) {
			if (!out[key] && current?.[key]) out[key] = current[key];
		}
		if (!out.totalMiB && current?.totalMiB) out.totalMiB = current.totalMiB;
		return out;
	}

	function displayDeviceForSaved(device) {
		const current = usableDevices().find((item) => item.name === device.name);
		if (current && !isVMInternalRPCDevice(device)) return mergeSavedDevice(current, device);
		const vm = vmDeviceForRPCSelection(device);
		if (vm) return { ...vm, location: "vEGPU VM" };
		return mergeSavedDevice(current, device);
	}

	function savedDeviceLabel(device) {
		return deviceDisplayLabel(displayDeviceForSaved(device));
	}

	function argValue(args, name) {
		if (!Array.isArray(args)) return "";
		for (let i = 0; i < args.length; i += 1) {
			const value = String(args[i] ?? "");
			if (value === name) return String(args[i + 1] ?? "");
			if (value.startsWith(`${name}=`)) return value.slice(name.length + 1);
		}
		return "";
	}

	function modelRouteSummary(model) {
		if (!model) return "";
		const status = modelStatusInfo(model);
		const runtime = status.runtime ?? {};
		const args = Array.isArray(status.args) && status.args.length ? status.args : runtime.args ?? [];
		const backend = String(runtime.backend || model.launch?.runtimeKind || "").toLowerCase();
		const savedDevices = (model.launch?.devices ?? []).map(savedDeviceLabel).join(", ");
		const devices = savedDevices || argValue(args, "--device");
		const rpc = argValue(args, "--rpc") || (model.launch?.rpcServers ?? []).join(",");
		const location =
			backend === "bridge" || /^cuda/i.test(String(model.launch?.devices?.[0]?.name ?? ""))
				? "VM llama-server"
				: "Mac llama-server";
		return [location, devices ? `devices ${devices}` : "", rpc ? `RPC ${rpc}` : ""].filter(Boolean).join(" · ");
	}

	function loadingText(model) {
		const summary = modelRouteSummary(model);
		return summary ? `Loading on ${summary}` : "Loading model";
	}

	function launch() {
		return state.draft?.launch ?? {};
	}

	function generation() {
		return state.draft?.generation ?? {};
	}

	function markDirty() {
		state.dirty = true;
		renderModelHeader();
		renderModelsList();
	}

	function setDraftField(key, value) {
		if (!state.draft) return;
		state.draft[key] = value;
		markDirty();
	}

	function setLaunchValue(key, value) {
		if (!state.draft) return;
		state.draft.launch ||= {};
		state.draft.launch[key] = value;
		markDirty();
	}

	function setGenerationValue(key, value) {
		if (!state.draft) return;
		state.draft.generation ||= {};
		state.draft.generation[key] = value;
		markDirty();
	}

	function numberFromInput(value) {
		if (String(value).trim() === "") return null;
		const parsed = Number(value);
		return Number.isNaN(parsed) ? null : parsed;
	}

	function boolFromSelect(value) {
		return value === "" ? null : value === "true";
	}

	function boolSelectValue(value) {
		return value === true ? "true" : value === false ? "false" : "";
	}

	function mmprojOffloadFromSelect(value) {
		if (value === "disable") return true;
		if (value === "enable") return false;
		return null;
	}

	function mmprojOffloadSelectValue(value) {
		return value === true ? "disable" : value === false ? "enable" : "";
	}

	function selectedLayerTotal() {
		return (launch().devices ?? []).reduce((sum, device) => sum + (Number(device.layers) || 0), 0);
	}

	function selectModel(id) {
		const model = state.models.find((item) => item.id === id);
		if (!model) return;
		state.selectedId = id;
		localStorage.setItem(selectedModelStorageKey, id);
		state.draft = clone(model);
		state.draft.launch ||= {};
		state.draft.generation ||= {};
		state.dirty = false;
		state.selectedDeviceName = "";
		renderModelsList();
		renderModelDetail();
	}

	function syncSelectedDraftFromModels() {
		if (!state.selectedId || !state.draft) return;
		const model = state.models.find((item) => item.id === state.selectedId);
		if (!model) return;
		if (!state.dirty) {
			state.draft = clone(model);
			state.draft.launch ||= {};
			state.draft.generation ||= {};
			return;
		}
		state.draft.metadata = {
			...(state.draft.metadata ?? {}),
			...(model.metadata ?? {})
		};
		state.draft.available = model.available;
		state.draft.missingReason = model.missingReason;
		state.draft.sizeBytes = model.sizeBytes;
	}

	function setModelsFromServer(models) {
		state.models = sortModelList(models ?? state.models);
		syncSelectedDraftFromModels();
	}

	function cleanObject(value) {
		const out = {};
		for (const [key, item] of Object.entries(value ?? {})) {
			if (item == null || item === "") continue;
			if (Array.isArray(item)) {
				const cleanedArray = item.filter((entry) => entry != null && entry !== "");
				if (cleanedArray.length > 0) out[key] = cleanedArray;
				continue;
			}
			if (typeof item === "object") {
				const nested = cleanObject(item);
				if (Object.keys(nested).length > 0) out[key] = nested;
				continue;
			}
			out[key] = item;
		}
		return out;
	}

	function cleanModel(model) {
		const cleaned = clone(model);
		cleaned.launch = cleanObject(cleaned.launch ?? {});
		cleaned.generation = cleanObject(cleaned.generation ?? {});
		if (Object.keys(cleaned.launch).length === 0) delete cleaned.launch;
		if (Object.keys(cleaned.generation).length === 0) delete cleaned.generation;
		return cleaned;
	}

	async function loadAll() {
		state.loading = true;
		setError("");
		setStatus("Loading router settings");
		try {
			const configData = await apiFetch("/api/config");
			state.appConfig = normalizeAppConfig(configData.config);
			state.routerEndpoints = normalizeRouterEndpoints(configData.routerEndpoints, state.appConfig);
			setModelsFromServer(configData.models ?? Object.values(state.appConfig.models ?? {}));
			if (!state.selectedId) {
				const remembered = localStorage.getItem(selectedModelStorageKey);
				const next = state.models.find((model) => model.id === remembered) ?? state.models[0];
				if (next) selectModel(next.id);
			}
			renderAll();
			setStatus("Ready");
			void refreshRouterModels(false).then(renderAll).catch(showError);
			void refreshRuntime(false).then(renderAll).catch(showError);
			void refreshRuntimeReleases(false).then(renderAll).catch(showError);
			void refreshRuntimes(false).then(renderAll).catch(showError);
			void refreshDevices(false).then(renderAll).catch(showError);
			void refreshDownloads(true, false).then(renderDownloads).catch(showError);
			void refreshModelCopies(true, false).then(renderModelTransfers).catch(showError);
			void apiFetch("/api/runtime/flags")
				.then((data) => {
					state.runtimeFlags = data.flags ?? [];
					renderModelDetail();
				})
				.catch(showError);
		} catch (error) {
			showError(error);
		} finally {
			state.loading = false;
		}
	}

	async function refreshRouterModels(render = true) {
		const data = await apiFetch("/models");
		const next = {};
		const details = {};
		for (const model of data.data ?? []) {
			const reported = model.status?.value ?? "unloaded";
			if (reported === "loaded" || reported === "failed") {
				state.pendingModelLoads.delete(model.id);
			}
			next[model.id] = state.pendingModelLoads.has(model.id) && reported === "unloaded" ? "loading" : reported;
			details[model.id] = { ...(model.status ?? {}), value: next[model.id] };
		}
		state.modelStatuses = next;
		state.modelStatusDetails = details;
		updateModelStatusPolling();
		if (render) {
			renderModelsList();
			renderModelHeader();
			if (state.draft && modelStatus(state.draft) === "loading") renderModelDetail();
		}
	}

	function updateModelStatusPolling() {
		const hasLoading = Object.values(state.modelStatuses).some((status) => status === "loading");
		if (hasLoading && !modelStatusTimer) {
			modelStatusTimer = window.setInterval(() => {
				refreshRouterModels(true).catch(showError);
			}, 1500);
		} else if (!hasLoading && modelStatusTimer) {
			window.clearInterval(modelStatusTimer);
			modelStatusTimer = null;
		}
	}

	async function refreshModels() {
		setStatus("Scanning model folders");
		const data = await apiFetch("/api/models/refresh", { method: "POST", body: "{}" });
		state.models = sortModelList(data.models ?? state.models);
		if (state.selectedId) {
			const stillExists = state.models.find((model) => model.id === state.selectedId);
			if (stillExists) selectModel(stillExists.id);
		} else if (state.models[0]) {
			selectModel(state.models[0].id);
		}
		await refreshRouterModels(false);
		renderAll();
		setStatus(`Added ${data.added?.length ?? 0} model(s)`);
	}

	async function refreshRuntime(render = true) {
		state.runtimeStatus = await apiFetch("/api/runtime/status");
		if (render) renderServer();
	}

	async function refreshRuntimes(render = true) {
		state.runtimes = await apiFetch("/api/runtimes");
		updateRuntimeInstallPolling();
		if (render) renderRuntimes();
	}

	function updateRuntimeInstallPolling() {
		const pairs = state.runtimes?.pairs ?? [];
		const hasPendingInstall = pairs.some((pair) => !pair.vmInstalled && !pair.installError && !pair.vmDeletePending);
		if (!hasPendingInstall) {
			if (runtimeInstallPollTimer) {
				window.clearTimeout(runtimeInstallPollTimer);
				runtimeInstallPollTimer = null;
			}
			runtimeInstallPollStartedAt = 0;
			return;
		}
		const now = Date.now();
		if (!runtimeInstallPollStartedAt) runtimeInstallPollStartedAt = now;
		if (now - runtimeInstallPollStartedAt > 120000 || runtimeInstallPollTimer) return;
		runtimeInstallPollTimer = window.setTimeout(() => {
			runtimeInstallPollTimer = null;
			refreshRuntimes(true).catch(showError);
		}, 3000);
	}

	async function refreshRuntimeReleases(render = true) {
		const data = await apiFetch(`/api/runtimes/releases?family=${encodeURIComponent(state.runtimeFamily)}`);
		state.runtimeReleases = data.releases ?? [];
		if (render) renderRuntimeReleaseControls();
	}

	async function refreshDevices(render = true) {
		const data = await apiFetch("/api/devices");
		state.devices = data.devices ?? [];
		state.deviceError = data.error || "";
		if (render) {
			renderDevices();
			renderModelDetail();
		}
	}

	async function saveConfig(config) {
		const data = await apiFetch("/api/config", {
			method: "PATCH",
			body: JSON.stringify({ config })
		});
		state.appConfig = normalizeAppConfig(data.config);
		state.routerEndpoints = normalizeRouterEndpoints(data.routerEndpoints, state.appConfig);
		setStatus("Settings saved");
		renderServer();
		renderDevices();
	}

	async function saveServerSettings() {
		if (!state.appConfig) return;
		const config = normalizeAppConfig(clone(state.appConfig));
		config.server = {
			...(config.server ?? {}),
			host: el.serverHostInput.value.trim() || "127.0.0.1",
			port: Number(el.serverPortInput.value || 9292),
			apiKeys: csv(el.serverApiKeysInput.value),
			allowInsecureRemote: el.serverAllowInsecureSelect.value === "true"
		};
		config.runtime ||= {};
		config.runtime.residency ||= {};
		config.runtime.residency.residencyMode = el.serverResidencyModeSelect?.value || "gpu-aware";
		config.runtime.residency.maxActiveServers = Number(el.serverMaxActiveInput?.value ?? 0);
		await saveConfig(config);
	}

	function addRPCServer() {
		if (!state.appConfig) return;
		state.appConfig.rpcServers = [...(state.appConfig.rpcServers ?? []), { endpoint: "", enabled: true }];
		renderRPCRows();
	}

	function updateRPCServer(index, patch) {
		if (!state.appConfig) return;
		const servers = [...(state.appConfig.rpcServers ?? [])];
		servers[index] = { ...servers[index], ...patch };
		state.appConfig.rpcServers = servers;
	}

	function removeRPCServer(index) {
		if (!state.appConfig) return;
		const servers = [...(state.appConfig.rpcServers ?? [])];
		servers.splice(index, 1);
		state.appConfig.rpcServers = servers;
		renderRPCRows();
	}

	async function saveRPCServers() {
		if (!state.appConfig) return;
		const data = await apiFetch("/api/rpc", {
			method: "PUT",
			body: JSON.stringify({ rpcServers: state.appConfig.rpcServers ?? [] })
		});
		state.appConfig.rpcServers = data.rpcServers ?? [];
		await refreshDevices(false);
		renderDevices();
		renderModelDetail();
		setStatus("RPC saved");
	}

	async function saveModel() {
		if (!state.selectedId || !state.draft) return;
		state.saving = true;
		renderModelHeader();
		setError("");
		try {
			if (state.draft.generation?.custom && typeof state.draft.generation.custom === "string") {
				JSON.parse(state.draft.generation.custom);
			}
			const saved = await apiFetch(`/api/models/${encodeURIComponent(state.selectedId)}`, {
				method: "PATCH",
				body: JSON.stringify(cleanModel(state.draft))
			});
			state.models = state.models.map((model) => (model.id === state.selectedId ? saved : model));
			state.draft = clone(saved);
			state.draft.launch ||= {};
			state.draft.generation ||= {};
			state.dirty = false;
			await refreshRouterModels(false);
			renderAll();
			setStatus("Model saved");
			return true;
		} catch (error) {
			showError(error);
			return false;
		} finally {
			state.saving = false;
			renderModelHeader();
		}
	}

	async function deleteModel() {
		const model = state.models.find((item) => item.id === state.selectedId);
		if (!model) return;
		const paths = [model.modelPath, model.mmprojPath].filter(Boolean).join("\n");
		if (!window.confirm(`Delete this model config and these files?\n\n${paths}`)) return;
		await apiFetch(`/api/models/${encodeURIComponent(model.id)}`, { method: "DELETE" });
		state.models = state.models.filter((item) => item.id !== model.id);
		state.selectedId = null;
		state.draft = null;
		state.dirty = false;
		if (state.models[0]) selectModel(state.models[0].id);
		renderAll();
		setStatus("Model deleted");
	}

	async function copySelectedModel() {
		const model = state.models.find((item) => item.id === state.selectedId);
		if (!model) return;
		const label = copyModelLabel(model);
		if (!label) return;
		setStatus(`${label} queued`);
		const task = await apiFetch(`/api/models/${encodeURIComponent(model.id)}/copy`, {
			method: "POST",
			body: "{}"
		});
		state.modelCopies = [task, ...state.modelCopies.filter((item) => item.id !== task.id)];
		renderModelTransfers();
		await refreshModelCopies(true);
	}

	async function loadModel() {
		if (!state.selectedId) return;
		if (state.dirty) {
			setStatus("Saving model before load");
			const saved = await saveModel();
			if (!saved) return;
		}
		const model = state.draft;
		state.pendingModelLoads.add(state.selectedId);
		state.modelStatuses = { ...state.modelStatuses, [state.selectedId]: "loading" };
		state.modelStatusDetails = {
			...state.modelStatusDetails,
			[state.selectedId]: { value: "loading", args: [], runtime: { args: [] } }
		};
		setStatus(loadingText(model));
		renderModelsList();
		renderModelHeader();
		renderModelDetail();
		updateModelStatusPolling();
		try {
			await apiFetch("/models/load", {
				method: "POST",
				body: JSON.stringify({ model: state.selectedId })
			});
			state.pendingModelLoads.delete(state.selectedId);
			await refreshRouterModels(false);
			setStatus("Model loaded");
		} catch (error) {
			state.pendingModelLoads.delete(state.selectedId);
			await refreshRouterModels(false).catch(() => {});
			throw error;
		} finally {
			renderModelsList();
			renderModelHeader();
			renderModelDetail();
			updateModelStatusPolling();
		}
	}

	async function unloadModel() {
		if (!state.selectedId) return;
		setStatus("Unloading model");
		await apiFetch("/models/unload", {
			method: "POST",
			body: JSON.stringify({ model: state.selectedId })
		});
		await refreshRouterModels(false);
		renderModelsList();
		renderModelHeader();
		setStatus("Unload requested");
	}

	function addPrimaryDevice() {
		const device = usableDevices()[0];
		if (!device) return;
		state.selectedDeviceName = device.name;
		addModelDevice();
	}

	function addModelDevice() {
		if (!state.selectedDeviceName) return;
		const current = [...(launch().devices ?? [])];
		const selected =
			availableDevicesForAdd().find((device) => device.name === state.selectedDeviceName) ||
			usableDevices().find((device) => device.name === state.selectedDeviceName);
		if (!selected) return;
		const totalLayers = modelLayerCount(state.draft) ?? null;
		const usedLayers = current.reduce((sum, device) => sum + (Number(device.layers) || 0), 0);
		current.push({
			name: selected.name,
			label: selected.label || selected.description || "",
			backend: selected.backend || "",
			totalMiB: selected.totalMiB || 0,
			minTotalMiB: selected.totalMiB || 0,
			pciAddress: selected.pciAddress || "",
			uuid: selected.uuid || "",
			remote: !!selected.remote,
			endpoint: selected.endpoint || "",
			location: selected.location || "",
			layers: totalLayers ? Math.max(0, totalLayers - usedLayers) : null
		});
		if (totalLayers && current.length > 1 && usedLayers === 0) {
			const base = Math.floor(totalLayers / current.length);
			let remainder = totalLayers % current.length;
			for (const device of current) {
				device.layers = base + (remainder > 0 ? 1 : 0);
				remainder -= 1;
			}
		}
		setLaunchValue("devices", current);
		if (!launch().mainGpuDevice) setLaunchValue("mainGpuDevice", current[0]?.name ?? "");
		state.selectedDeviceName = "";
		renderModelDetail();
	}

	function distributeLayers(devicesToUpdate = [...(launch().devices ?? [])], total = modelLayerCount(state.draft)) {
		if (!total || devicesToUpdate.length === 0) return;
		const base = Math.floor(total / devicesToUpdate.length);
		let remainder = total % devicesToUpdate.length;
		const next = devicesToUpdate.map((device) => {
			const layers = base + (remainder > 0 ? 1 : 0);
			remainder -= 1;
			return { ...device, layers };
		});
		setLaunchValue("devices", next);
		renderModelDetail();
	}

	function updateModelDevice(index, patch) {
		const current = [...(launch().devices ?? [])];
		current[index] = { ...current[index], ...patch };
		setLaunchValue("devices", current);
	}

	function removeModelDevice(index) {
		const current = [...(launch().devices ?? [])];
		const removed = current[index];
		current.splice(index, 1);
		setLaunchValue("devices", current);
		if (removed?.name === launch().mainGpuDevice) setLaunchValue("mainGpuDevice", current[0]?.name ?? "");
		renderModelDetail();
	}

	function moveModelDevice(index, delta) {
		const current = [...(launch().devices ?? [])];
		const target = index + delta;
		if (target < 0 || target >= current.length) return;
		[current[index], current[target]] = [current[target], current[index]];
		setLaunchValue("devices", current);
		if (index === 0 || target === 0) setLaunchValue("mainGpuDevice", current[0]?.name ?? "");
		renderModelDetail();
	}

	function dropModelDevice(target) {
		if (state.dragDeviceIndex === null || state.dragDeviceIndex === target) return;
		const current = [...(launch().devices ?? [])];
		const from = state.dragDeviceIndex;
		const [item] = current.splice(from, 1);
		current.splice(target, 0, item);
		state.dragDeviceIndex = null;
		setLaunchValue("devices", current);
		if (from === 0 || target === 0) setLaunchValue("mainGpuDevice", current[0]?.name ?? "");
		renderModelDetail();
	}

	async function listHF() {
		if (!state.hfRepo.trim()) {
			setError("Hugging Face repo is required");
			return;
		}
		setStatus("Listing Hugging Face files");
		const params = new URLSearchParams({
			repo: state.hfRepo.trim(),
			revision: state.hfRevision.trim() || "main",
			path: state.hfPath.trim(),
			recursive: state.hfRecursive ? "true" : "false"
		});
		const data = await apiFetch(`/api/hf/tree?${params.toString()}`);
		state.hfEntries = data.entries ?? [];
		state.hfCheckedPaths = new Set();
		renderHFEntries();
		setStatus("Ready");
	}

	function toggleHFPath(entry, checked) {
		const next = new Set(state.hfCheckedPaths);
		const affected =
			entry.type === "directory"
				? state.hfEntries
						.filter((item) => item.type === "file" && item.path.startsWith(`${entry.path}/`))
						.map((item) => item.path)
				: [entry.path];
		for (const path of affected) {
			if (checked) next.add(path);
			else next.delete(path);
		}
		state.hfCheckedPaths = next;
		renderHFEntries();
	}

	async function downloadHF() {
		const paths = [...state.hfCheckedPaths];
		if (paths.length === 0) return;
		await apiFetch("/api/hf/download", {
			method: "POST",
			body: JSON.stringify({
				repo: state.hfRepo.trim(),
				revision: state.hfRevision.trim() || "main",
				paths,
				location: state.hfLocation
			})
		});
		setStatus("Download queued");
		await refreshDownloads(true);
	}

	async function refreshDownloads(keepPolling = false, render = true) {
		const data = await apiFetch("/api/hf/downloads");
		const now = Date.now();
		for (const download of data.downloads ?? []) {
			const prev = state.downloadStats.get(download.id);
			let speed = prev?.speed ?? 0;
			if (prev && now > prev.time && download.downloadedBytes >= prev.bytes) {
				speed = (download.downloadedBytes - prev.bytes) / ((now - prev.time) / 1000);
			}
			state.downloadStats.set(download.id, {
				bytes: download.downloadedBytes ?? 0,
				time: now,
				speed
			});
		}
		state.downloads = data.downloads ?? [];
		if (state.downloadTimer) clearTimeout(state.downloadTimer);
		const active = state.downloads.some(
			(download) => download.status === "queued" || download.status === "running"
		);
		if ((keepPolling || active) && active) {
			state.downloadTimer = setTimeout(() => {
				refreshDownloads(true).catch(showError);
			}, 1200);
		}
		if (render) renderDownloads();
	}

	async function refreshModelCopies(keepPolling = false, render = true) {
		const data = await apiFetch("/api/model-copies");
		const now = Date.now();
		for (const copy of data.copies ?? []) {
			const prev = state.modelCopyStats.get(copy.id);
			let speed = prev?.speed ?? 0;
			if (prev && now > prev.time && (copy.downloadedBytes ?? 0) >= prev.bytes) {
				speed = ((copy.downloadedBytes ?? 0) - prev.bytes) / ((now - prev.time) / 1000);
			}
			state.modelCopyStats.set(copy.id, {
				bytes: copy.downloadedBytes ?? 0,
				time: now,
				speed
			});
		}
		state.modelCopies = data.copies ?? [];
		if (state.modelCopyTimer) clearTimeout(state.modelCopyTimer);
		const active = state.modelCopies.some((copy) => copy.status === "queued" || copy.status === "running");
		if ((keepPolling || active) && active) {
			state.modelCopyTimer = setTimeout(() => {
				refreshModelCopies(true).catch(showError);
			}, 1000);
		}
		if (render) renderModelTransfers();
		if (!active) {
			await loadConfigOnly().catch(() => {});
			await refreshRouterModels(false).catch(() => {});
			renderModelsList();
			renderModelDetail();
		}
	}

	function setHFPath(path) {
		state.hfPath = path;
		el.hfPathInput.value = path;
		listHF().catch(showError);
	}

	async function fetchInstallSelectedRuntime() {
		const tag = el.runtimeReleaseSelect?.value || state.runtimeReleases[0]?.tag || "";
		if (!tag) throw new Error("Choose a release first");
		await fetchInstallRuntime(tag, el.runtimeLinuxBackendSelect?.value || state.runtimeLinuxBackend);
	}

	async function fetchInstallRuntime(tag, linuxBackend) {
		state.runtimeFetching = true;
		renderRuntimes();
		try {
			setStatus("Fetching matched runtime release");
			const data = await apiFetch("/api/runtimes/fetch-install", {
				method: "POST",
				body: JSON.stringify({
					family: state.runtimeFamily,
					tag,
					linuxBackend: linuxBackend || "cuda13"
				})
			});
			state.runtimes = data.runtimes ?? state.runtimes;
			await Promise.all([loadConfigOnly(), refreshRuntime(false), refreshRuntimes(false), refreshDevices(false)]);
			renderAll();
			setStatus(data.pair?.installError ? "Runtime ready on macOS; VM install needs retry" : "Matched runtime installed");
		} finally {
			state.runtimeFetching = false;
			renderRuntimes();
		}
	}

	async function activateRuntimePair(id) {
		if (!id) throw new Error("Choose a runtime pair first");
		const pair = findRuntimePair(id);
		state.runtimePairPending.set(id, pair?.installError ? "Installing VM" : "Selecting");
		renderRuntimes();
		try {
			setStatus(pair?.installError ? "Installing VM runtime" : "Selecting matched runtime");
			const data = await apiFetch("/api/runtimes/pair/activate", {
				method: "POST",
				body: JSON.stringify({ id })
			});
			state.runtimes = data.runtimes ?? state.runtimes;
			await Promise.all([loadConfigOnly(), refreshRuntime(false), refreshRuntimes(false), refreshDevices(false)]);
			renderAll();
			setStatus(data.pair?.installError ? "VM runtime install needs retry" : "Matched runtime selected");
		} finally {
			state.runtimePairPending.delete(id);
			renderRuntimes();
		}
	}

	async function activateSelectedRuntimePair() {
		await activateRuntimePair(el.pairedRuntimeSelect?.value || "");
	}

	async function deleteRuntimePair(id) {
		if (!id) throw new Error("Choose a runtime pair first");
		state.runtimePairPending.set(id, "Deleting");
		renderRuntimes();
		try {
			setStatus("Deleting runtime pair");
			const data = await apiFetch("/api/runtimes/pair/delete", {
				method: "POST",
				body: JSON.stringify({ id })
			});
			state.runtimes = data.runtimes ?? state.runtimes;
			await refreshRuntimes(false);
			renderAll();
			const stillPending = findRuntimePair(id)?.vmDeletePending;
			setStatus(stillPending ? "Runtime pair delete is pending VM cleanup" : "Runtime pair deleted");
		} finally {
			state.runtimePairPending.delete(id);
			renderRuntimes();
		}
	}

	async function deleteSelectedRuntimePair() {
		await deleteRuntimePair(el.pairedRuntimeSelect?.value || "");
	}

	function findRuntimePair(id) {
		return (state.runtimes?.pairs ?? []).find((pair) => pair.id === id);
	}

	async function loadConfigOnly() {
		const configData = await apiFetch("/api/config");
		state.appConfig = normalizeAppConfig(configData.config);
		state.routerEndpoints = normalizeRouterEndpoints(configData.routerEndpoints, state.appConfig);
		setModelsFromServer(configData.models ?? Object.values(state.appConfig.models ?? {}));
	}

	function renderAll() {
		renderServer();
		renderRuntimes();
		renderDevices();
		renderModelsList();
		renderModelDetail();
		renderDownloadModal();
	}

	function renderServer() {
		if (!state.appConfig) return;
		const server = state.appConfig.server ?? {};
		el.serverHostInput.value = server.host ?? "127.0.0.1";
		el.serverPortInput.value = server.port ?? 9292;
		el.serverApiKeysInput.value = (server.apiKeys ?? []).join(",");
		el.serverAllowInsecureSelect.value = String(!!server.allowInsecureRemote);
		state.routerEndpoints = normalizeRouterEndpoints(state.routerEndpoints, state.appConfig);
		if (el.macApiEndpoint) el.macApiEndpoint.textContent = state.routerEndpoints.macBaseURL;
		if (el.vmApiEndpoint) el.vmApiEndpoint.textContent = state.routerEndpoints.vmBaseURL;
		const residency = state.appConfig.runtime?.residency ?? {};
		if (el.serverResidencyModeSelect) el.serverResidencyModeSelect.value = residency.residencyMode ?? "gpu-aware";
		if (el.serverMaxActiveInput) el.serverMaxActiveInput.value = residency.maxActiveServers ?? 0;
		const runtime = state.runtimeStatus;
		if (!runtime) {
			el.runtimeSummary.textContent = "Runtime status loading...";
		} else {
			el.runtimeSummary.textContent = runtime.error
				? "Runtime status check failed"
				: runtime.exists
					? "Runtime found"
					: "Runtime missing";
		}
		renderEndpoints();
	}

	function renderRuntimes() {
		if (!el.runtimeCards || !el.runtimeInstallSummary) return;
		const payload = state.runtimes;
		renderRuntimeReleaseControls();
		if (!payload) {
			el.runtimeInstallSummary.textContent = "Bundled and user-managed runtime pairs loading...";
			el.runtimeCards.innerHTML = `<div class="empty-state">No runtime data yet.</div>`;
			renderRuntimePairSelector([]);
			return;
		}
		const pairs = payload.pairs ?? [];
		el.runtimeInstallSummary.textContent = `${pairs.length} bundled or user-managed runtime pair${pairs.length === 1 ? "" : "s"}`;
		renderRuntimePairSelector(pairs);
		if (pairs.length === 0) {
			el.runtimeCards.innerHTML = `<div class="empty-state">No matched runtime pairs installed.</div>`;
			return;
		}
		el.runtimeCards.innerHTML = pairs
			.map((pair) => {
				const error = pair.installError ? compactError(pair.installError) : "";
				const active = !!pair.active;
				const pending = state.runtimePairPending.get(pair.id) || "";
				const busy = !!pending;
				const deleting = pending === "Deleting";
				const backend = backendLabel(pair.linuxBackend);
				const mac = pair.macos ?? {};
				const linux = pair.linux ?? {};
				return `
				<article class="runtime-card ${active ? "runtime-card-active" : ""} ${busy ? "runtime-card-pending" : ""}">
					<div class="runtime-card-head">
						<div>
							<h3>${escapeHTML(pairLabel(pair))}</h3>
							<p>${escapeHTML(backend)}</p>
						</div>
						<div class="runtime-badges">
							${pending ? `<span class="status-pill status-loading">${escapeHTML(pending)}</span>` : ""}
							${active ? `<span class="status-pill status-loaded">active</span>` : ""}
							${pair.vmInstalled ? `<span class="status-pill">VM installed</span>` : ""}
							${!pair.vmInstalled && !error ? `<span class="status-pill">VM pending</span>` : ""}
							${pair.vmDeletePending ? `<span class="status-pill status-failed">VM delete pending</span>` : ""}
						</div>
					</div>
					<div class="runtime-meta">
						<div><span>macOS</span><code title="${escapeHTML(mac.assetName || mac.archiveName || "")}">${escapeHTML(mac.assetName || mac.archiveName || "not installed")}</code></div>
						<div><span>Linux VM</span><code title="${escapeHTML(linux.assetName || linux.archiveName || "")}">${escapeHTML(linux.assetName || linux.archiveName || "not installed")}</code></div>
						${pair.sourceRef ? `<div><span>source ref</span><code>${escapeHTML(pair.sourceRef)}</code></div>` : ""}
						${mac.version ? `<div><span>version</span><code>${escapeHTML(compactOneLine(mac.version))}</code></div>` : ""}
						${pending ? `<div class="runtime-progress"><span>install</span><code>${escapeHTML(pending)}...</code></div>` : ""}
						${error ? `<div class="runtime-error"><span>install</span><code>${escapeHTML(error)}</code></div>` : ""}
					</div>
					<div class="inline-actions runtime-card-actions">
						<button class="mini-button" type="button" ${active || busy ? "disabled" : ""} data-runtime-pair-activate="${escapeHTML(pair.id)}">${active ? "Active" : busy && !deleting ? "Installing..." : "Use"}</button>
						${error ? `<button class="mini-button" type="button" ${busy ? "disabled" : ""} data-runtime-pair-activate="${escapeHTML(pair.id)}">${busy && !deleting ? "Installing..." : "Retry VM Install"}</button>` : ""}
						<button class="mini-button mini-button-danger" type="button" ${active || busy ? "disabled" : ""} data-runtime-pair-delete="${escapeHTML(pair.id)}">${deleting ? "Deleting..." : "Delete"}</button>
					</div>
				</article>`;
			})
			.join("");
	}

	function renderRuntimeReleaseControls() {
		if (el.runtimeFamilySelect) el.runtimeFamilySelect.value = state.runtimeFamily;
		if (el.runtimeLinuxBackendSelect) {
			el.runtimeLinuxBackendSelect.value = state.runtimeLinuxBackend;
		}
		if (el.runtimeReleaseSelect) {
			const previous = el.runtimeReleaseSelect.value;
			const selected = state.runtimeReleases.some((release) => release.tag === previous)
				? previous
				: state.runtimeReleases[0]?.tag || "";
			el.runtimeReleaseSelect.innerHTML =
				state.runtimeReleases.length === 0
					? `<option value="">No releases loaded</option>`
					: state.runtimeReleases
							.map((release) => `<option value="${escapeHTML(release.tag)}">${escapeHTML(releaseLabel(release))}</option>`)
							.join("");
			el.runtimeReleaseSelect.value = selected;
			el.runtimeReleaseSelect.disabled = state.runtimeReleases.length === 0 || state.runtimeFetching;
		}
		if (el.fetchRuntimeButton) {
			el.fetchRuntimeButton.disabled = state.runtimeFetching || state.runtimeReleases.length === 0;
			el.fetchRuntimeButton.textContent = state.runtimeFetching ? "Installing..." : "Fetch & Install";
		}
	}

	function renderRuntimePairSelector(pairs) {
		const select = el.pairedRuntimeSelect;
		if (!select) return;
		const active = pairs.find((pair) => pair.active);
		const previous = select.value;
		const selected = pairs.some((pair) => pair.id === previous) ? previous : active?.id || pairs[0]?.id || "";
		select.innerHTML =
			pairs.length === 0
				? `<option value="">No matched runtime pairs installed</option>`
				: pairs
						.map((pair) => `<option value="${escapeHTML(pair.id)}">${escapeHTML(pairLabel(pair))}</option>`)
						.join("");
		select.value = selected;
		select.disabled = pairs.length === 0;
		const pair = findRuntimePair(select.value);
		const busy = !!pair && state.runtimePairPending.has(pair.id);
		if (el.usePairRuntimeButton) {
			el.usePairRuntimeButton.disabled = !pair || pair.active || busy;
			el.usePairRuntimeButton.textContent = busy ? "Installing..." : pair?.active ? "Active" : "Use";
		}
		if (el.retryPairRuntimeButton) {
			el.retryPairRuntimeButton.disabled = !pair || !pair.installError || busy;
			el.retryPairRuntimeButton.textContent = busy ? "Installing..." : "Retry VM Install";
		}
		if (el.deletePairRuntimeButton) {
			el.deletePairRuntimeButton.disabled = !pair || pair.active || busy;
			el.deletePairRuntimeButton.textContent = state.runtimePairPending.get(pair?.id) === "Deleting" ? "Deleting..." : "Delete";
		}
	}

	function pairLabel(pair) {
		if (!pair) return "";
		const family = pair.family === "turbo" ? "TurboQuant" : "llama.cpp";
		const tag = pair.sourceRef || pair.releaseTag || pair.id;
		return `${family} ${tag} (${backendLabel(pair.linuxBackend)})`;
	}

	function releaseLabel(release) {
		const family = release.family === "turbo" ? "TurboQuant" : "llama.cpp";
		const tag = release.sourceRef || release.tag;
		return `${family} ${tag}`;
	}

	function backendLabel(value) {
		return value === "vulkan" ? "Vulkan" : "CUDA 13";
	}

	function compactOneLine(text) {
		const line = String(text ?? "")
			.split(/\r?\n/)
			.map((item) => item.trim())
			.find(Boolean);
		if (!line) return "";
		return line.length > 60 ? `${line.slice(0, 57)}...` : line;
	}

	function compactError(text) {
		const lines = String(text ?? "")
			.split(/\r?\n/)
			.map((line) => line.trim())
			.filter(Boolean);
		if (lines.length === 0) return "";
		const lastError = [...lines].reverse().find((line) => /error|failed|invalid/i.test(line));
		const summary = lastError || lines[lines.length - 1];
		return summary.length > 220 ? `${summary.slice(0, 217)}...` : summary;
	}

	function renderEndpoints() {
		el.endpointsButton.setAttribute("aria-expanded", String(state.endpointsOpen));
		el.endpointsPopover.classList.toggle("hidden", !state.endpointsOpen);
		const routerEndpoints = normalizeRouterEndpoints(state.routerEndpoints, state.appConfig);
		const bases = [
			{ method: "Mac", path: routerEndpoints.macBaseURL },
			{ method: "VM", path: routerEndpoints.vmBaseURL }
		];
		el.endpointsPopover.innerHTML = bases
			.concat(advertisedEndpoints)
			.map(
				(endpoint) => `
				<div class="endpoint-row">
					<span class="endpoint-method">${escapeHTML(endpoint.method)}</span>
					<span class="endpoint-path" title="${escapeHTML(endpoint.path)}">${escapeHTML(endpoint.path)}</span>
					<button class="mini-button" type="button" data-copy-endpoint="${escapeHTML(endpoint.path)}">Copy</button>
				</div>`
			)
			.join("");
	}

	function renderDevices() {
		const usable = usableDevices();
		el.deviceSummary.textContent = `${usable.length} detected device${usable.length === 1 ? "" : "s"}`;
		el.deviceErrorBox.textContent = state.deviceError ? `Device probe warning: ${compactError(state.deviceError)}` : "";
		el.deviceErrorBox.title = state.deviceError || "";
		el.deviceErrorBox.classList.toggle("hidden", !state.deviceError);
		el.toggleRPCButton.setAttribute("aria-expanded", String(state.rpcExpanded));
		el.rpcEditor.classList.toggle("hidden", !state.rpcExpanded);
		renderRPCRows();
		if (usable.length === 0) {
			el.devicesTableBody.innerHTML = `<tr><td colspan="6" class="muted">No devices reported.</td></tr>`;
			return;
		}
		el.devicesTableBody.innerHTML = usable
			.map(
				(device) => `
				<tr>
					<td><strong>${escapeHTML(device.name)}</strong></td>
					<td>${escapeHTML(device.backend || "")}</td>
					<td>${escapeHTML(device.freeMiB ?? 0)} MiB</td>
					<td>${escapeHTML(device.totalMiB ?? 0)} MiB</td>
					<td class="mono" title="${escapeHTML(device.location || (device.remote ? device.endpoint || "RPC" : "local"))}">${escapeHTML(
						device.location || (device.remote ? device.endpoint || "RPC" : "local")
					)}</td>
					<td title="${escapeHTML(device.description || "")}">${escapeHTML(device.description || "")}</td>
				</tr>`
			)
			.join("");
	}

	function renderRPCRows() {
		if (!state.appConfig) return;
		const servers = state.appConfig.rpcServers ?? [];
		if (servers.length === 0) {
			el.rpcRows.innerHTML = `<p class="muted">No RPC servers configured.</p>`;
			return;
		}
		el.rpcRows.innerHTML = servers
			.map(
				(rpc, index) => `
				<div class="rpc-row" data-rpc-index="${index}">
					<label class="field">
						<span>endpoint</span>
						<input class="input" data-rpc-field="endpoint" placeholder="host:port or rpc://host:port" value="${escapeHTML(
							rpc.endpoint ?? ""
						)}" />
					</label>
					<label class="field">
						<span>enabled</span>
						<select class="input" data-rpc-field="enabled">
							<option value="true" ${rpc.enabled ? "selected" : ""}>enabled</option>
							<option value="false" ${!rpc.enabled ? "selected" : ""}>disabled</option>
						</select>
					</label>
					<button class="button button-secondary" type="button" data-rpc-remove="${index}">Remove</button>
				</div>`
			)
			.join("");
	}

	function filteredModels() {
		const needle = state.modelFilter.trim().toLowerCase();
		const type = state.modelTypeFilter.trim().toLowerCase();
		return state.models.filter((model) => {
			if (isHiddenModel(model)) return false;
			if (type && modelKind(model) !== type) return false;
			if (!needle) return true;
			return [
				model.id,
				model.name,
				model.provider,
				model.source,
				model.location,
				model.modelPath,
				model.mmprojPath,
				model.metadata?.format,
				modelArchitecture(model),
				modelKindLabel(modelKind(model))
			]
				.filter(Boolean)
				.join(" ")
				.toLowerCase()
				.includes(needle);
		});
	}

	function renderModelsList() {
		const filtered = filteredModels();
		el.modelsCountText.textContent = `${filtered.length} of ${state.models.length}`;
		if (filtered.length === 0) {
			el.modelsList.innerHTML = `<div class="empty-state">No models found.</div>`;
			return;
		}
		el.modelsList.innerHTML = filtered
			.map((model) => {
				const status = modelStatus(model);
				return `
				<button class="model-row ${model.id === state.selectedId ? "selected" : ""}" type="button" data-model-id="${escapeHTML(
					model.id
				)}">
					<span class="model-row-name" title="${escapeHTML(model.name || model.id)}">${escapeHTML(
						model.name || model.id
					)}</span>
					<span class="model-row-meta">
						<span class="status-pill ${statusClass(status)}">${escapeHTML(status)}</span>
						<span>${escapeHTML(modelKindLabel(modelKind(model)))}</span>
						${modelArchitecture(model) ? `<span>${escapeHTML(modelArchitecture(model))}</span>` : ""}
						<span>${escapeHTML(model.provider || "unknown")}</span>
						<span>${escapeHTML(formatBytes(model.sizeBytes))}</span>
					</span>
					<span class="model-row-path mono" title="${escapeHTML(modelPathDisplay(model))}">${escapeHTML(
						modelPathDisplay(model)
					)}</span>
				</button>`;
			})
			.join("");
	}

	function renderModelHeader() {
		if (!state.draft) return;
		const status = modelStatus(state.draft);
		const activeCopy = selectedModelCopyActive();
		el.modelTitle.textContent = state.draft.name || state.draft.id;
		el.modelSubline.textContent = status === "loading"
			? loadingText(state.draft)
			: state.dirty
			? "Unsaved changes"
			: state.draft.available
				? state.draft.id
				: state.draft.missingReason || state.draft.id;
		el.saveModelButton.disabled = !state.dirty || state.saving;
		el.loadModelButton.disabled = status === "loading" || !state.draft.available || state.saving;
		const copyLabel = copyModelLabel(state.draft);
		if (el.copyModelHeaderButton) {
			el.copyModelHeaderButton.textContent = copyLabel || "Copy model";
			el.copyModelHeaderButton.disabled = !copyLabel || state.saving || activeCopy;
			el.copyModelHeaderButton.title = copyLabel || copyModelUnavailableReason(state.draft);
		}
	}

	function selectedModelCopyActive() {
		return state.modelCopies.some(
			(copy) =>
				copy.modelId === state.selectedId &&
				(copy.status === "queued" || copy.status === "running")
		);
	}

	function renderModelTransfers() {
		if (!el.modelTransferPanel) return;
		const copies = state.modelCopies.filter((copy) => copy.modelId === state.selectedId).slice(0, 3);
		el.modelTransferPanel.classList.toggle("hidden", copies.length === 0);
		if (copies.length === 0) {
			el.modelTransferPanel.innerHTML = "";
			return;
		}
		el.modelTransferPanel.innerHTML = copies
			.map((copy) => {
				const total = Number(copy.totalBytes ?? 0);
				const copied = Number(copy.downloadedBytes ?? 0);
				const percent =
					copy.status === "complete"
						? 100
						: total > 0
							? Math.max(0, Math.min(100, (copied / total) * 100))
							: 0;
				const speed = state.modelCopyStats.get(copy.id)?.speed ?? 0;
				const direction = `${String(copy.sourceLocation || "").toUpperCase()} -> ${String(
					copy.targetLocation || ""
				).toUpperCase()}`;
				return `
				<div class="model-transfer-item">
					<div class="download-item-head">
						<span>${escapeHTML(copy.status)}</span>
						<span class="muted">${escapeHTML(direction)}</span>
						<span class="muted">${escapeHTML(formatBytes(speed) || "0 B")}/s</span>
					</div>
					<p>${escapeHTML(copy.current || copy.modelName || copy.modelId || "model copy")}</p>
					<p>${escapeHTML(formatBytesRequired(copied))}/${escapeHTML(
						total > 0 ? formatBytesRequired(total) : "unknown"
					)} ${total > 0 ? `(${percent.toFixed(1)}%)` : ""}</p>
					<div class="progress-track"><div class="progress-bar" style="width: ${percent}%"></div></div>
					${copy.error ? `<p class="danger-text">${escapeHTML(copy.error)}</p>` : ""}
				</div>`;
			})
			.join("");
	}

	function renderModelDetail() {
		if (!state.draft) {
			el.modelEmptyState.classList.remove("hidden");
			el.modelDetail.classList.add("hidden");
			el.modelForm.innerHTML = "";
			if (el.modelTransferPanel) el.modelTransferPanel.innerHTML = "";
			return;
		}
		el.modelEmptyState.classList.add("hidden");
		el.modelDetail.classList.remove("hidden");
		renderModelHeader();
		renderModelTransfers();
		el.modelForm.innerHTML = renderModelFormHTML();
	}

	function selectedLayerStatus() {
		const total = modelLayerCount(state.draft);
		if (total) return `${selectedLayerTotal()} / ${total} layers assigned`;
		return "Layer count unavailable; split values are saved as llama.cpp tensor split ratios.";
	}

	function inputField(label, scope, key, value, extra = "") {
		return `
			<label class="field ${extra}">
				<span>${escapeHTML(label)}</span>
				<input class="input" data-scope="${scope}" data-key="${escapeHTML(key)}" value="${escapeHTML(value ?? "")}" />
			</label>`;
	}

	function numberField(label, scope, key, value, step = "1", extra = "") {
		return `
			<label class="field ${extra}">
				<span>${escapeHTML(label)}</span>
				<input class="input" type="number" step="${escapeHTML(step)}" data-type="number" data-scope="${scope}" data-key="${escapeHTML(
					key
				)}" value="${escapeHTML(value ?? "")}" />
			</label>`;
	}

	function textareaField(label, scope, key, value, type = "text", extra = "") {
		return `
			<label class="field ${extra}">
				<span>${escapeHTML(label)}</span>
				<textarea class="input" data-type="${escapeHTML(type)}" data-scope="${scope}" data-key="${escapeHTML(
					key
				)}">${escapeHTML(value ?? "")}</textarea>
			</label>`;
	}

	function selectField(label, scope, key, value, options, type = "text", extra = "") {
		return `
			<label class="field ${extra}">
				<span>${escapeHTML(label)}</span>
				<select class="input" data-type="${escapeHTML(type)}" data-scope="${scope}" data-key="${escapeHTML(key)}">
					${options
						.map((option) => {
							const valueText = typeof option === "string" ? option : option.value;
							const labelText =
								typeof option === "string" ? option || "unset" : option.label || option.value || "unset";
							return `<option value="${escapeHTML(valueText)}" ${
								String(value ?? "") === String(valueText) ? "selected" : ""
							}>${escapeHTML(labelText)}</option>`;
						})
						.join("")}
				</select>
			</label>`;
	}

	function sectionHTML(title, body, note = "", actions = "") {
		return `
			<section class="form-section">
				<div class="form-section-head">
					<div>
						<h3>${escapeHTML(title)}</h3>
						${note ? `<p class="section-note">${escapeHTML(note)}</p>` : ""}
					</div>
					${actions ? `<div class="inline-actions">${actions}</div>` : ""}
				</div>
				${body}
			</section>`;
	}

	function renderModelFormHTML() {
		const l = launch();
		const g = generation();
		const totalLayers = modelLayerCount(state.draft);
		const maxTokens = modelContextLength(state.draft);
		const task = inferModelTask(state.draft);
		const status = modelStatus(state.draft);
		const addDeviceOptions = [
			{ value: "", label: "Select GPU" },
			...availableDevicesForAdd().map((device) => ({
				value: device.name,
				label: deviceDisplayLabel(device)
			}))
		];
		const mainDeviceName = l.mainGpuDevice || (l.devices ?? [])[0]?.name || "";
		const selectedDevicesHTML =
			(l.devices ?? []).length === 0
				? `<p class="muted device-selected-list">No GPU or RPC devices selected yet.</p>`
				: `<div class="device-selected-list">
					${(l.devices ?? [])
						.map((device, index) => {
							const label = savedDeviceLabel(device);
							const primary = mainDeviceName ? device.name === mainDeviceName : index === 0;
							return `
							<div class="selected-device-row" draggable="true" data-device-row="${index}">
								<div class="selected-device-name">
									<strong>${escapeHTML(primary ? "Primary GPU" : "GPU")}</strong>
									<span title="${escapeHTML(label)}">${escapeHTML(label)}</span>
								</div>
								<label class="field">
									<span>Layers ${totalLayers ? `<span class="muted">of ${escapeHTML(totalLayers)}</span>` : ""}</span>
									<input class="input" type="number" min="0" ${totalLayers ? `max="${escapeHTML(totalLayers)}"` : ""} data-device-index="${index}" value="${escapeHTML(
										device.layers ?? ""
									)}" />
								</label>
								<div class="inline-actions">
									<button class="mini-button" type="button" data-device-action="up" data-device-index="${index}">Up</button>
									<button class="mini-button" type="button" data-device-action="down" data-device-index="${index}">Down</button>
									<button class="mini-button" type="button" data-device-action="remove" data-device-index="${index}">Remove</button>
								</div>
							</div>`
						})
						.join("")}
				</div>`;
		return [
			sectionHTML(
				"GPU Routing and Primary Settings",
				`
				${selectedDevicesHTML}
				<div class="device-add-row">
					<select id="selectedDeviceSelect" class="input">
						${addDeviceOptions
							.map(
								(option) =>
									`<option value="${escapeHTML(option.value)}" ${
										state.selectedDeviceName === option.value ? "selected" : ""
									}>${escapeHTML(option.label)}</option>`
							)
							.join("")}
					</select>
				</div>
				<div class="form-grid three">
					${numberField("Context size", "launch", "ctxSize", l.ctxSize)}
					${numberField("Max tokens", "launch", "maxTokens", l.maxTokens)}
					${numberField("Parallel slots", "launch", "parallel", l.parallel)}
					${numberField("Batch size", "launch", "batchSize", l.batchSize)}
					${numberField("Micro batch", "launch", "ubatchSize", l.ubatchSize)}
					${numberField("TTL seconds", "launch", "ttl", l.ttl)}
					${selectField("Flash attention", "launch", "flashAttn", l.flashAttn ?? "on", [
						"on",
						"off",
						"auto"
					])}
					${selectField(
						"Unified KV cache",
						"launch",
						"kvUnified",
						boolSelectValue(l.kvUnified) || ((l.devices ?? []).length > 1 ? "false" : "true"),
						["", "true", "false"],
						"bool"
					)}
					${selectField(
						"K cache quantization (suggest q8_0)",
						"launch",
						"cacheTypeK",
						l.cacheTypeK ?? "",
						cacheTypes
					)}
					${selectField(
						"V cache quantization (suggest turbo3)",
						"launch",
						"cacheTypeV",
						l.cacheTypeV ?? "",
						cacheTypes
					)}
				</div>`,
				selectedLayerStatus(),
				`<button id="balanceLayersButton" class="button button-secondary" type="button" ${
					(l.devices ?? []).length === 0 || !totalLayers ? "disabled" : ""
				}>Balance Layers</button>`
			),
			sectionHTML(
				"Identity and Files",
				`
				<div class="form-grid two">
					${inputField("Name", "draft", "name", state.draft.name)}
					${inputField("Description", "draft", "description", state.draft.description)}
					${inputField(`${modelLocationLabel(state.draft)} GGUF path`, "draft", "modelPath", state.draft.modelPath, "span-2")}
					${inputField("mmproj path", "draft", "mmprojPath", state.draft.mmprojPath, "span-2")}
				</div>`
			),
				sectionHTML(
					"Generation and Sampling",
					`
					<div class="form-grid three">
						${numberField("Temperature", "generation", "temperature", g.temperature, "0.01")}
						${numberField("Dynamic temp range", "generation", "dynatemp_range", g.dynatemp_range, "0.01")}
						${numberField("Dynamic temp exponent", "generation", "dynatemp_exponent", g.dynatemp_exponent, "0.01")}
					${numberField("Top K", "generation", "top_k", g.top_k)}
					${numberField("Top P", "generation", "top_p", g.top_p, "0.01")}
					${numberField("Min P", "generation", "min_p", g.min_p, "0.01")}
					${numberField("Typical P", "generation", "typ_p", g.typ_p, "0.01")}
					${numberField("XTC probability", "generation", "xtc_probability", g.xtc_probability, "0.01")}
					${numberField("XTC threshold", "generation", "xtc_threshold", g.xtc_threshold, "0.01")}
					${inputField("Samplers", "generation", "samplers", g.samplers)}
					${selectField(
						"Backend sampling",
						"generation",
						"backend_sampling",
						boolSelectValue(g.backend_sampling),
						["", "true", "false"],
						"bool"
					)}
				</div>`
			),
			sectionHTML(
				"Penalties and Custom API Defaults",
				`
				<div class="form-grid three">
					${numberField("Repeat last N", "generation", "repeat_last_n", g.repeat_last_n)}
					${numberField("Repeat penalty", "generation", "repeat_penalty", g.repeat_penalty, "0.01")}
					${numberField("Presence penalty", "generation", "presence_penalty", g.presence_penalty, "0.01")}
					${numberField("Frequency penalty", "generation", "frequency_penalty", g.frequency_penalty, "0.01")}
					${numberField("DRY multiplier", "generation", "dry_multiplier", g.dry_multiplier, "0.01")}
					${numberField("DRY base", "generation", "dry_base", g.dry_base, "0.01")}
					${numberField("DRY allowed length", "generation", "dry_allowed_length", g.dry_allowed_length)}
					${numberField("DRY penalty last N", "generation", "dry_penalty_last_n", g.dry_penalty_last_n)}
					${textareaField("Custom JSON", "generation", "custom", g.custom, "text", "span-all")}
				</div>`
			),
			sectionHTML(
				"Endpoints and Multimodal",
				`
				<div class="form-grid three">
					${maxTokens ? `<div class="hint-box">Model supports up to <span class="mono">${escapeHTML(maxTokens)}</span> tokens.</div>` : ""}
					${selectField(
						"Embeddings API endpoint",
						"launch",
						"embedding",
						boolSelectValue(l.embedding),
						["", "true", "false"],
						"bool"
					)}
					${selectField("Pooling", "launch", "pooling", l.pooling ?? "", [
						"",
						"none",
						"mean",
						"cls",
						"last",
						"rank"
					])}
					${
						task
							? `<div class="hint-box">Detected likely ${escapeHTML(
									task
								)} model. Enable the embeddings endpoint and use pooling rank for rerank models when needed.</div>`
							: ""
					}
				</div>`
			),
			sectionHTML(
				"Speculative Draft, Extra Args, and Env",
				`
				<div class="form-grid two">
					${textareaField("Extra runtime args", "launch", "extraArgs", (l.extraArgs ?? []).join("\n"), "lines")}
					${textareaField("Environment, KEY=value per line", "launch", "env", (l.env ?? []).join("\n"), "lines")}
				</div>`
			),
			sectionHTML(
				"Runtime Flag Catalog",
				`
				<div class="runtime-flags">
					${
						state.runtimeFlags.length === 0
							? `<div class="empty-state">No runtime flag data.</div>`
							: state.runtimeFlags
									.map(
										(flag) => `
										<div class="flag-row">
											<span class="mono">--${escapeHTML(flag.name ?? "")}</span>
											<span class="muted">${escapeHTML(flag.category ?? "")}</span>
											<span class="muted">${escapeHTML(flag.description ?? "")}</span>
										</div>`
									)
									.join("")
					}
				</div>`
			)
		].join("");
	}

	function renderDownloadModal() {
		el.downloadModal.classList.toggle("hidden", !state.downloadOpen);
		if (!state.downloadOpen) return;
		el.hfRepoInput.value = state.hfRepo;
		el.hfRevisionInput.value = state.hfRevision;
		el.hfPathInput.value = state.hfPath;
		el.hfLocationSelect.value = state.hfLocation;
		el.hfRecursiveInput.checked = state.hfRecursive;
		renderDownloads();
		renderHFEntries();
	}

	function renderDownloads() {
		if (state.downloads.length === 0) {
			el.downloadsList.innerHTML = `<p class="muted">No downloads.</p>`;
			return;
		}
		el.downloadsList.innerHTML = state.downloads
			.map((download) => {
				const total = Number(download.totalBytes ?? 0);
				const downloaded = Number(download.downloadedBytes ?? 0);
				const completePercent =
					download.status === "complete"
						? 100
						: total > 0
							? Math.max(0, Math.min(100, (downloaded / total) * 100))
							: 0;
				const speed = state.downloadStats.get(download.id)?.speed ?? 0;
				return `
				<div class="download-item">
					<div class="download-item-head">
						<span>${escapeHTML(download.status)}</span>
						<span class="muted">${escapeHTML(String(download.location || "mac").toUpperCase())}</span>
						<span class="muted">${escapeHTML(formatBytes(speed) || "0 B")}/s</span>
					</div>
					<p>${escapeHTML(download.repo)} ${escapeHTML(download.revision || "")}</p>
					${download.current ? `<p class="muted">${escapeHTML(download.current)}</p>` : ""}
					<p>${escapeHTML(formatBytesRequired(downloaded))}/${escapeHTML(
						total > 0 ? formatBytesRequired(total) : "unknown"
					)}</p>
					<div class="progress-track"><div class="progress-bar" style="width: ${completePercent}%"></div></div>
					${download.error ? `<p class="danger-text">${escapeHTML(download.error)}</p>` : ""}
				</div>`;
			})
			.join("");
	}

	function renderHFEntries() {
		el.hfEntriesCount.textContent = `${state.hfEntries.length} entries`;
		if (state.hfEntries.length === 0) {
			el.hfEntriesList.innerHTML = `<div class="empty-state">No files listed.</div>`;
			return;
		}
		el.hfEntriesList.innerHTML = state.hfEntries
			.map((entry) => {
				const checked =
					entry.type === "directory"
						? state.hfEntries.some(
								(item) =>
									item.type === "file" &&
									item.path.startsWith(`${entry.path}/`) &&
									state.hfCheckedPaths.has(item.path)
							)
						: state.hfCheckedPaths.has(entry.path);
				return `
				<div class="hf-entry-row">
					<input type="checkbox" data-hf-path="${escapeHTML(entry.path)}" ${checked ? "checked" : ""} />
					<span class="tag">${escapeHTML(entry.type)}</span>
					<span class="hf-entry-path" title="${escapeHTML(entry.path)}">${escapeHTML(entry.path)}</span>
					<span class="muted">${escapeHTML(formatBytes(entry.size))}</span>
					${
						entry.type === "directory"
							? `<button class="mini-button" type="button" data-hf-open="${escapeHTML(entry.path)}">Open</button>`
							: ""
					}
				</div>`;
			})
			.join("");
	}

	function readTypedValue(input) {
		const type = input.dataset.type ?? "text";
		if (type === "number") return numberFromInput(input.value);
		if (type === "bool") return boolFromSelect(input.value);
		if (type === "mmprojOffload") return mmprojOffloadFromSelect(input.value);
		if (type === "lines") return lines(input.value);
		return input.value;
	}

	function handleModelControl(input) {
		const scope = input.dataset.scope;
		const key = input.dataset.key;
		if (!scope || !key) return;
		const value = readTypedValue(input);
		if (scope === "draft") setDraftField(key, value);
		if (scope === "launch") setLaunchValue(key, value);
		if (scope === "generation") setGenerationValue(key, value);
	}

	function showError(error) {
		console.error(error);
		setError(error instanceof Error ? error.message : String(error));
	}

	function wireEvents() {
		el.refreshAllButton?.addEventListener("click", () => loadAll().catch(showError));
		el.authSaveButton.addEventListener("click", async () => {
			setStoredApiKey(el.authApiKeyInput.value);
			el.authPanel.classList.add("hidden");
			await loadAll();
		});
		el.authApiKeyInput.addEventListener("keydown", (event) => {
			if (event.key === "Enter") el.authSaveButton.click();
		});
		el.saveServerButton.addEventListener("click", () => saveServerSettings().catch(showError));
		el.checkRuntimeButton.addEventListener("click", () => refreshRuntime().catch(showError));
		el.runtimeFamilySelect?.addEventListener("change", () => {
			state.runtimeFamily = el.runtimeFamilySelect.value || "llama";
			refreshRuntimeReleases(true).catch(showError);
		});
		el.runtimeLinuxBackendSelect?.addEventListener("change", () => {
			state.runtimeLinuxBackend = el.runtimeLinuxBackendSelect.value || "cuda13";
		});
		el.fetchRuntimeButton?.addEventListener("click", () => fetchInstallSelectedRuntime().catch(showError));
		el.pairedRuntimeSelect?.addEventListener("change", () => renderRuntimes());
		el.usePairRuntimeButton?.addEventListener("click", () => activateSelectedRuntimePair().catch(showError));
		el.retryPairRuntimeButton?.addEventListener("click", () => activateSelectedRuntimePair().catch(showError));
		el.deletePairRuntimeButton?.addEventListener("click", () => deleteSelectedRuntimePair().catch(showError));
		el.runtimeCards?.addEventListener("click", (event) => {
			const activate = event.target.closest("[data-runtime-pair-activate]");
			if (activate) {
				activateRuntimePair(activate.dataset.runtimePairActivate).catch(showError);
				return;
			}
			const remove = event.target.closest("[data-runtime-pair-delete]");
			if (remove && !remove.disabled) {
				deleteRuntimePair(remove.dataset.runtimePairDelete).catch(showError);
			}
		});
		el.endpointsButton.addEventListener("click", (event) => {
			event.stopPropagation();
			state.endpointsOpen = !state.endpointsOpen;
			renderEndpoints();
		});
		el.endpointsPopover.addEventListener("click", (event) => {
			const button = event.target.closest("[data-copy-endpoint]");
			if (!button) return;
			navigator.clipboard?.writeText(button.dataset.copyEndpoint ?? "");
			button.textContent = "Copied";
			setTimeout(() => {
				button.textContent = "Copy";
			}, 900);
		});
		document.addEventListener("click", (event) => {
			if (!event.target.closest(".endpoint-menu")) {
				state.endpointsOpen = false;
				renderEndpoints();
			}
		});
		el.toggleRPCButton.addEventListener("click", () => {
			state.rpcExpanded = !state.rpcExpanded;
			renderDevices();
		});
		el.refreshDevicesButton.addEventListener("click", () => refreshDevices().catch(showError));
		el.addRPCButton.addEventListener("click", addRPCServer);
		el.saveRPCButton.addEventListener("click", () => saveRPCServers().catch(showError));
		el.rpcRows.addEventListener("input", (event) => {
			const input = event.target.closest("[data-rpc-field]");
			if (!input) return;
			const row = input.closest("[data-rpc-index]");
			if (!row) return;
			const index = Number(row.dataset.rpcIndex);
			if (input.dataset.rpcField === "endpoint") updateRPCServer(index, { endpoint: input.value });
		});
		el.rpcRows.addEventListener("change", (event) => {
			const input = event.target.closest("[data-rpc-field]");
			if (!input) return;
			const row = input.closest("[data-rpc-index]");
			if (!row) return;
			const index = Number(row.dataset.rpcIndex);
			if (input.dataset.rpcField === "enabled") {
				updateRPCServer(index, { enabled: input.value === "true" });
			}
		});
		el.rpcRows.addEventListener("click", (event) => {
			const button = event.target.closest("[data-rpc-remove]");
			if (button) removeRPCServer(Number(button.dataset.rpcRemove));
		});
		el.modelFilterInput.addEventListener("input", () => {
			state.modelFilter = el.modelFilterInput.value;
			renderModelsList();
		});
		el.modelTypeSelect?.addEventListener("change", () => {
			state.modelTypeFilter = el.modelTypeSelect.value;
			renderModelsList();
		});
		el.refreshModelsButton.addEventListener("click", () => refreshModels().catch(showError));
		el.modelsList.addEventListener("click", (event) => {
			const row = event.target.closest("[data-model-id]");
			if (row) selectModel(row.dataset.modelId);
		});
		el.loadModelButton.addEventListener("click", () => loadModel().catch(showError));
		el.unloadModelButton.addEventListener("click", () => unloadModel().catch(showError));
		el.saveModelButton.addEventListener("click", () => saveModel().catch(showError));
		el.copyModelHeaderButton?.addEventListener("click", () => copySelectedModel().catch(showError));
		el.deleteModelButton.addEventListener("click", () => deleteModel().catch(showError));
		el.modelForm.addEventListener("input", (event) => {
			const deviceInput = event.target.closest("[data-device-index]");
			if (deviceInput && deviceInput.matches("input")) {
				updateModelDevice(Number(deviceInput.dataset.deviceIndex), {
					layers: numberFromInput(deviceInput.value)
				});
				const layerNote = el.modelForm.querySelector(".form-section .section-note");
				if (layerNote) layerNote.textContent = selectedLayerStatus();
				return;
			}
			const control = event.target.closest("[data-scope]");
			if (control && control.tagName !== "SELECT") handleModelControl(control);
		});
		el.modelForm.addEventListener("change", (event) => {
			const control = event.target.closest("[data-scope]");
			if (control) handleModelControl(control);
			if (event.target.id === "selectedDeviceSelect") {
				state.selectedDeviceName = event.target.value;
				if (state.selectedDeviceName) addModelDevice();
			}
		});
		el.modelForm.addEventListener("click", (event) => {
			const action = event.target.closest("[data-device-action]");
			if (action) {
				const index = Number(action.dataset.deviceIndex);
				if (action.dataset.deviceAction === "up") moveModelDevice(index, -1);
				if (action.dataset.deviceAction === "down") moveModelDevice(index, 1);
				if (action.dataset.deviceAction === "remove") removeModelDevice(index);
				return;
			}
			if (event.target.closest("#addPrimaryButton")) addPrimaryDevice();
			if (event.target.closest("#balanceLayersButton")) distributeLayers();
		});
		el.modelForm.addEventListener("dragstart", (event) => {
			const row = event.target.closest("[data-device-row]");
			if (!row) return;
			state.dragDeviceIndex = Number(row.dataset.deviceRow);
			row.classList.add("dragging");
		});
		el.modelForm.addEventListener("dragover", (event) => {
			if (event.target.closest("[data-device-row]")) event.preventDefault();
		});
		el.modelForm.addEventListener("drop", (event) => {
			const row = event.target.closest("[data-device-row]");
			if (!row) return;
			event.preventDefault();
			dropModelDevice(Number(row.dataset.deviceRow));
		});
		el.modelForm.addEventListener("dragend", () => {
			state.dragDeviceIndex = null;
			for (const row of el.modelForm.querySelectorAll(".dragging")) row.classList.remove("dragging");
		});
		el.openDownloadButton.addEventListener("click", () => {
			state.downloadOpen = true;
			renderDownloadModal();
			refreshDownloads(true).catch(showError);
		});
		el.closeDownloadButton.addEventListener("click", () => {
			state.downloadOpen = false;
			renderDownloadModal();
		});
		el.downloadBackdrop.addEventListener("click", () => {
			state.downloadOpen = false;
			renderDownloadModal();
		});
		document.addEventListener("keydown", (event) => {
			if (event.key === "Escape" && state.downloadOpen) {
				state.downloadOpen = false;
				renderDownloadModal();
			}
		});
		el.hfRepoInput.addEventListener("input", () => {
			state.hfRepo = el.hfRepoInput.value;
		});
		el.hfRevisionInput.addEventListener("input", () => {
			state.hfRevision = el.hfRevisionInput.value;
		});
		el.hfPathInput.addEventListener("input", () => {
			state.hfPath = el.hfPathInput.value;
		});
		el.hfLocationSelect.addEventListener("change", () => {
			state.hfLocation = el.hfLocationSelect.value || "mac";
		});
		el.hfRecursiveInput.addEventListener("change", () => {
			state.hfRecursive = el.hfRecursiveInput.checked;
		});
		el.listHFButton.addEventListener("click", () => listHF().catch(showError));
		el.downloadHFButton.addEventListener("click", () => downloadHF().catch(showError));
		el.hfEntriesList.addEventListener("change", (event) => {
			const input = event.target.closest("[data-hf-path]");
			if (!input) return;
			const entry = state.hfEntries.find((item) => item.path === input.dataset.hfPath);
			if (entry) toggleHFPath(entry, input.checked);
		});
		el.hfEntriesList.addEventListener("click", (event) => {
			const button = event.target.closest("[data-hf-open]");
			if (button) setHFPath(button.dataset.hfOpen);
		});
	}

	wireEvents();
	loadAll().catch(showError);
})();
