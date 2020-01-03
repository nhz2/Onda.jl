#####
##### `Dataset`
#####

struct Dataset{C}
    path::String
    header::Header
    recordings::Dict{UUID,Recording{C}}
end

"""
    Dataset(path, custom_type=Any; create=false, strict=())

Return a `Dataset` instance that contains all metadata necessary to read and
write to the Onda dataset stored at `path`. Note that this constuctor loads all
the `Recording` objects contained in `path/recordings.msgpack.zst`.

`custom_type` is the `typeof` of the `custom` value found in each `Recording`
object in the dataset.

If `create` is `true`, then an empty Onda dataset will be created at `path`.

The `strict` keyword argument is forwarded to `MsgPack.unpack` when that
function is called while parsing `path/recordings.msgpack.zst` (see the
MsgPack documentation for details regarding `strict`).
"""
function Dataset(path, custom_type::Type{C}=Any;
                 create::Bool=false, strict=()) where {C}
    path = rstrip(abspath(path), '/')
    samples_path = joinpath(path, "samples")
    if create
        endswith(path, ".onda") || throw(ArgumentError("cannot create dataset at $path: path does not end with .onda"))
        isdir(path) && throw(ArgumentError("cannot create dataset at $path: directory exists"))
        mkdir(path)
        mkdir(samples_path)
        initial_header = Header(ONDA_FORMAT_VERSION, true)
        initial_recordings = Dict{UUID,Recording{C}}()
        write_recordings_file(path, initial_header, initial_recordings)
    elseif !(isdir(path) && isdir(samples_path))
        throw(ArgumentError("$path is not a valid Onda dataset"))
    end
    header, recordings = read_recordings_file(path, C, strict)
    return Dataset{C}(path, header, recordings)
end

"""
    save_recordings_file(dataset::Dataset)

Overwrite `joinpath(dataset.path, "recordings.msgpack.zst")` with the contents
of `dataset.recordings`.
"""
function save_recordings_file(dataset::Dataset)
    return write_recordings_file(dataset.path, dataset.header, dataset.recordings)
end

Base.@deprecate overwrite_recordings(dataset) save_recordings_file(dataset)

#####
##### `merge!`
#####

"""
    merge!(destination::Dataset, datasets::Dataset...; only_recordings::Bool=false)

Write all filesystem content and the `recordings` field of each `Dataset` in
`datasets` to `destination`.

If any filesystem content has a name that conflicts with existing filesystem
content in `destination`, this function will throw an error. An error will also
be thrown if this function encounters multiple recordings with the same UUID.

If `only_recordings` is `true`, then only the `recordings` field of each `Dataset`
is merged, such that no filesystem content is read or written.

NOTE: This function is currently only implemented when `only_recordings = true`.
"""
function Base.merge!(destination::Dataset, datasets::Dataset...; only_recordings::Bool=false)
    only_recordings || error("`merge!(datasets::Dataset...; only_recordings=false)` is not yet implemented")
    for dataset in datasets
        for uuid in keys(dataset.recordings)
            if haskey(destination.recordings, uuid)
                throw(ArgumentError("recording $uuid already exists in the destination dataset"))
            end
        end
        merge!(destination.recordings, dataset.recordings)
    end
    return destination
end

#####
##### `samples_path`
#####

"""
    samples_path(dataset::Dataset, uuid::UUID)

Return the samples subdirectory path corresponding to the recording specified by `uuid`.
"""
samples_path(dataset::Dataset, uuid::UUID) = joinpath(dataset.path, "samples", string(uuid))

"""
    samples_path(dataset::Dataset, uuid::UUID, name::Symbol,
                 file_extension=dataset.recordings[uuid].signals[name].file_extension)

Return the samples file path corresponding to the signal named `name` within the
recording specified by `uuid`.
"""
function samples_path(dataset::Dataset, uuid::UUID, name::Symbol,
                      file_extension=dataset.recordings[uuid].signals[name].file_extension)
    file_name = string(name, ".", file_extension)
    return joinpath(samples_path(dataset, uuid), file_name)
end

#####
##### `create_recording!`
#####

"""
    create_recording!(dataset::Dataset{C}, duration::Nanosecond, custom=nothing)

Create `uuid::UUID => recording::Recording` where `recording` is constructed
via the provided `duration` and `custom` fields, add the pair to
`dataset.recordings`, and return the pair.

The `custom` argument is passed along to the `Recording{C}` constructor, such
that `custom isa C` must hold true.
"""
function create_recording!(dataset::Dataset{C}, duration::Nanosecond,
                           custom=nothing) where {C}
    uuid = uuid4()
    recording = Recording{C}(duration, Dict{Symbol,Signal}(), Set{Annotation}(), custom)
    dataset.recordings[uuid] = recording
    mkpath(samples_path(dataset, uuid))
    return uuid => recording
end

#####
##### `load`
#####

"""
    load(dataset::Dataset, uuid::UUID, name::Symbol[, span::AbstractTimeSpan])

Load and return the `Samples` object corresponding to the signal named `name`
in the recording specified by `uuid`.

If `span` is provided, this function returns the equivalent of
`load(dataset, uuid, name)[:, span]`, but potentially avoids loading the entire
signal's worth of sample data if the underlying signal file format supports
partial access/random seeks.

See also: [`deserialize_lpcm`](@ref)
"""
function load(dataset::Dataset, uuid::UUID, name::Symbol, span::AbstractTimeSpan...)
    signal = dataset.recordings[uuid].signals[name]
    path = samples_path(dataset, uuid, name, signal.file_extension)
    return load_samples(path, signal, span...)
end

"""
    load(dataset::Dataset, uuid::UUID, names[, span::AbstractTimeSpan])

Return `Dict(name => load(dataset, uuid, name[, span]) for name in names)`.
"""
function load(dataset::Dataset, uuid::UUID, names, span::AbstractTimeSpan...)
    return Dict(name => load(dataset, uuid, name, span...) for name in names)
end

"""
    load(dataset::Dataset, uuid::UUID[, span::AbstractTimeSpan])

Return `load(dataset, uuid, names[, span])` where `names` is a list of all
signal names in the recording specified by `uuid`.
"""
function load(dataset::Dataset, uuid::UUID, span::AbstractTimeSpan...)
    return load(dataset, uuid, keys(dataset.recordings[uuid].signals), span...)
end

#####
##### `store!`
#####

"""
    store!(dataset::Dataset, uuid::UUID, name::Symbol, samples::Samples;
           overwrite::Bool=true)

Add `name => samples.signal` to `dataset.recordings[uuid].signals` and serialize
`samples.data` to the proper file location within `dataset.path`.

If `overwrite` is `false`, an error is thrown if `samples` already exists
in `recording`/`dataset`. Otherwise, existing entries matching `samples.signal`
will be deleted and replaced with `samples`.
"""
function store!(dataset::Dataset, uuid::UUID, name::Symbol,
                samples::Samples; overwrite::Bool=true)
    recording, signal = dataset.recordings[uuid], samples.signal
    if haskey(recording.signals, name) && !overwrite
        throw(ArgumentError("$name already exists in $uuid and `overwrite` is `false`"))
    end
    is_valid(signal) || throw(ArgumentError("signal in `samples` is invalid"))
    if !is_lower_snake_case_alphanumeric(string(name))
        throw(ArgumentError("$name is not lower snake case and alphanumeric"))
    end
    recording.signals[name] = signal
    store_samples!(samples_path(dataset, uuid, name, signal.file_extension),
                   samples; overwrite=overwrite)
    return recording
end

#####
##### `delete!`
#####

"""
    delete!(dataset::Dataset, uuid::UUID)

Delete the recording whose UUID matches `uuid` from `dataset`. This function
removes the matching `Recording` object from `dataset.recordings`, as well as
deletes the corresponding subdirectory in the `dataset`'s `recordings` directory.
"""
function Base.delete!(dataset::Dataset, uuid::UUID)
    delete!(dataset.recordings, uuid)
    rm(samples_path(dataset, uuid); recursive=true, force=true)
    return dataset
end
