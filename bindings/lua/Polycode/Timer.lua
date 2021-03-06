require "Polycode/EventDispatcher"

class "Timer" (EventDispatcher)

Timer.EVENT_TRIGGER = 0

function Timer:Timer(...)
	local arg = {...}
	if type(arg[1]) == "table" and count(arg) == 1 then
		if ""..arg[1].__classname == "EventDispatcher" then
			self.__ptr = arg[1].__ptr
			return
		end
	end
	for k,v in pairs(arg) do
		if type(v) == "table" then
			if v.__ptr ~= nil then
				arg[k] = v.__ptr
			end
		end
	end
	if self.__ptr == nil and arg[1] ~= "__skip_ptr__" then
		self.__ptr = Polycode.Timer(unpack(arg))
	end
end

function Timer:Pause(paused)
	local retVal = Polycode.Timer_Pause(self.__ptr, paused)
end

function Timer:isPaused()
	local retVal =  Polycode.Timer_isPaused(self.__ptr)
	return retVal
end

function Timer:getTicks()
	local retVal =  Polycode.Timer_getTicks(self.__ptr)
	return retVal
end

function Timer:Update(ticks)
	local retVal = Polycode.Timer_Update(self.__ptr, ticks)
end

function Timer:Reset()
	local retVal =  Polycode.Timer_Reset(self.__ptr)
end

function Timer:hasElapsed()
	local retVal =  Polycode.Timer_hasElapsed(self.__ptr)
	return retVal
end

function Timer:getElapsedf()
	local retVal =  Polycode.Timer_getElapsedf(self.__ptr)
	return retVal
end

function Timer:setTimerInterval(msecs)
	local retVal = Polycode.Timer_setTimerInterval(self.__ptr, msecs)
end

function Timer:__delete()
	if self then Polycode.delete_Timer(self.__ptr) end
end
