package com.kaltura.hls.m2ts
{
    import flash.utils.ByteArray;
    import flash.net.ObjectEncoding;
    import flash.utils.ByteArray;
    import flash.utils.Endian;    
    import flash.utils.IDataInput;
    import flash.utils.IDataOutput;

    /**
     * Parser for MPEG 2 Transport Stream packets.
     * 
     * Responsible for converting a stream of TS packets into elementary 
     * streams ready for processing.
     */
    public class TSPacketParser
    {
        public static var logHeaders:Boolean = false;

        private var _buffer:ByteArray = new ByteArray();
        private var _streams:Object = {}; // of TSPacketStream
        private var _totalConsumed:int = 0;
        public var pesProcessor:PESProcessor = new PESProcessor();

        public function set callback(value:Function):void
        {
            pesProcessor.transcoder.callback = value;
        }

        /**
         * Accepts arbitrary chunks of bytes and extracts TS packet data.
         */
        public function appendBytes(bytes:ByteArray):void
        {
            // Append the bytes.
            _buffer.position = _buffer.length;
            _buffer.writeBytes(bytes, 0, bytes.length);
            
            // Set up parsing state.
            var cursor:uint = 0;
            var len:uint = _buffer.length;
            
            // Consume TS packets.
            while(true)
            {
                var scanCount:int = 0;
                while(cursor + 188 < len)
                {
                    if(0x47 == _buffer[cursor])  // search for TS sync byte
                        break;

                    cursor++;
                    scanCount++;
                }

                if(scanCount > 0)
                    trace("WARNING: appendBytes - skipped " + scanCount + " bytes to sync point.");
                
                // Confirm we have something to read.
                if(!(cursor + 188 < len))
                    break;
                
                parseTSPacket(cursor);
                
                // Advance counters.
                cursor += 188;
                _totalConsumed += cursor;
            }

            // Shift remainder into beginning of buffer and try again later.
            if(cursor > 0)
            {
                var remainder:uint = _buffer.length - cursor;
                _buffer.position = 0;
                _buffer.writeBytes(_buffer, cursor, remainder);
                _buffer.length = remainder;
            }
        }

        protected function parseTSPacket(cursor:int):void
        {
            var headerLength:uint = 4;
            var payloadLength:uint;
            var discontinuity:Boolean = false;

            // Decode the Transport Stream Header
            _buffer.position = cursor;
            const headerRaw:uint = _buffer.readUnsignedInt();

            const raw_syncByte:uint         = (headerRaw & 0xff000000) >> 24;
            const raw_tei:Boolean           = (headerRaw & 0x00800000) != 0;
            const raw_pusi:Boolean          = (headerRaw & 0x00400000) != 0;
            const raw_tp:Boolean            = (headerRaw & 0x00200000) != 0;
            const raw_pid:uint              = (headerRaw & 0x001fff00) >> 8;
            const raw_scramble:uint         = (headerRaw & 0x000000c0) >> 6;
            const raw_hasAdaptation:Boolean = (headerRaw & 0x00000020) != 0;
            const raw_hasPayload:Boolean    = (headerRaw & 0x00000010) != 0;
            const raw_continuity:uint       = (headerRaw & 0x0000000f);

            if(logHeaders)
            {
                trace("TS Pkt @" + _totalConsumed + " sync=" + raw_syncByte + " pid=" + raw_pid + " tei=" + raw_tei + " pusi=" + raw_pusi + " tp=" + raw_tp + " scramble=" + raw_scramble + " adapt? " + raw_hasAdaptation + " continuity=" + raw_continuity);
            }

            // Handle adaptation field.
            if(raw_hasAdaptation)
            {
                var adaptationFieldLength:uint = _buffer.readUnsignedByte();
                if(adaptationFieldLength >= 183)
                {
                    //trace("Saw only adaptation data, skipping TS packet.");
                    return;
                }

                headerLength += adaptationFieldLength + 1;
                
                discontinuity = (_buffer.readUnsignedByte() & 0x80) != 0;
            }
            
            payloadLength = 188 - headerLength;

            // Process payload.            
            if(!raw_hasPayload)
                return;

            if(raw_pid == 0x1fff)
            {
                trace("Skipping padding TS packet.");
                return;
            }

            // Allocate packet stream if none present.
            var stream:TSPacketStream = getPacketStream(raw_pid);

            if(stream.lastContinuity == raw_continuity)
            {
                // Ignore duplicate packets.
                if( (!raw_hasPayload)
                 && (!discontinuity))
                {
                    trace("WARNING: duplicate packet!");
                    return; // duplicate
                }
            }
            
            if(raw_pusi)
            {
                if(stream.buffer.length > 0 && stream.packetLength > 0)
                {
                    trace("WARNING: Flushed " + stream.buffer.length + " due to payloadStart flag, didn't predict length properly! (Guessed " + stream.packetLength + ")");
                }

                completeStreamPacket(stream);
            }
            else
            {
                if(stream.lastContinuity < 0)
                {
                    trace("WARNING: Saw discontinuous packet!");
                    return;
                }
                
                if( (((stream.lastContinuity + 1) & 0x0f) != raw_continuity) 
                    && !discontinuity)
                {
                    // Corrupt packet - skip it.
                    trace("WARNING: Saw corrupt packet, skipping!");
                    stream.buffer.length = 0;
                    stream.lastContinuity = -1;
                    return;
                }

                if(stream.buffer.length == 0 && length > 0)
                    trace("WARNING: Got new bytes without PUSI set!");
            }
            
            // Append to end.
            stream.buffer.position = stream.buffer.length;
            if(payloadLength > 0)
                stream.buffer.writeBytes(_buffer, cursor + headerLength, payloadLength);

            // Update continuity.
            stream.lastContinuity = raw_continuity;
            
            // Check to see if we can optimistically fire a complete PES packet...
            if(stream.packetLength > 0 && stream.buffer.length >= stream.packetLength + 6)
            {
                if(stream.buffer.length > stream.packetLength + 6)
                    trace("WARNING: Got buffer strictly longer (" + (stream.buffer.length - (stream.packetLength + 6)) + " bytes longer) than expected. This is OK when on first packet of stream.");
                completeStreamPacket(stream);
                stream.finishedLast = true;
            }
        }

        /**
         * We have a complete packet, append to the vector.
         */
        protected function completeStreamPacket(stream:TSPacketStream):void
        {
            if(stream.buffer.length == 0)
            {
                if(!stream.finishedLast)
                    trace("Tried to complete zero length packet.");
                stream.finishedLast = false;
                return;
            }

            // Append to buffer.
            if(!pesProcessor.append(new PESPacket(stream.packetID, stream.buffer)))
                return;

            // Reset stream buffer if we succeeded.
            stream.buffer.position = 0;
            stream.buffer.length = 0;
        }

        public function flush():void
        {
            trace("FLUSHING");
            for (var idx:* in _streams)
            {
                trace("Flushing stream id " + idx + " which has " + _streams[idx].buffer.length);
                completeStreamPacket(_streams[idx]);
            }

            pesProcessor.processAllNalus();

            pesProcessor.clear(true);
        }

        public function clear(clearAACConfig:Boolean = true):void
        {
            _streams = {};
            pesProcessor.clear(clearAACConfig);
        }

        /**
         * Fire off a subtitle caption.
         */
        public function createAndSendCaptionMessage( timestamp:Number, captionBuffer:String, lang:String="", textid:Number=99):void
        {
            pesProcessor.transcoder.createAndSendCaptionMessage( timestamp, captionBuffer, lang, textid);
        }

        /**
         * Allocate or retrieve the packet stream state for a given packet ID.
         */
        protected function getPacketStream(pid:int):TSPacketStream
        {
            var stream:TSPacketStream = _streams[pid];
            if(!stream)
            {
                stream = new TSPacketStream();
                stream.packetID = pid;
                _streams[pid] = stream;
            }
            return stream;
        }
    }
}