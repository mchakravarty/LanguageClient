import Foundation
import LanguageServerProtocol
import JSONRPC

#if canImport(ProcessEnv)
import ProcessEnv

#if compiler(>=5.9)

extension FileHandle {
	public var dataStream: AsyncStream<Data> {
		let (stream, continuation) = AsyncStream<Data>.makeStream()

		readabilityHandler = { handle in
			let data = handle.availableData

			if data.isEmpty {
				handle.readabilityHandler = nil
				continuation.finish()
				return
			}

			continuation.yield(data)
		}

		return stream
	}
}

extension DataChannel {
	@available(macOS 12.0, *)
	public static func localProcessChannel(
		parameters: Process.ExecutionParameters,
		terminationHandler: @escaping @Sendable () -> Void
	) throws -> DataChannel {
		let process = Process()

		let stdinPipe = Pipe()
		let stdoutPipe = Pipe()
		let stderrPipe = Pipe()

		process.standardInput = stdinPipe
		process.standardOutput = stdoutPipe
		process.standardError = stderrPipe

		process.parameters = parameters

		let (stream, continuation) = DataSequence.makeStream()

		process.terminationHandler = { _ in
			continuation.finish()
			terminationHandler()
		}

		Task {
			let dataStream = stdoutPipe.fileHandleForReading.dataStream
			let byteStream = AsyncByteSequence(base: dataStream)
			let framedData = AsyncMessageFramingSequence(base: byteStream)

			for try await data in framedData {
				continuation.yield(data)
			}

			continuation.finish()
		}

		Task {
			for try await line in stderrPipe.fileHandleForReading.bytes.lines {
				print("stderr: ", line)
			}
		}

		try process.run()

		let handler: DataChannel.WriteHandler = {
			// this is wacky, but we need the channel to hold a strong reference to the process
			// to prevent it from being deallocated
			_ = process

			let data = MessageFraming.frame($0)

			try stdinPipe.fileHandleForWriting.write(contentsOf: data)
		}

		return DataChannel(writeHandler: handler, dataSequence: stream)
	}
}
#endif

#endif
