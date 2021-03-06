class "Rotation"


function Rotation:__getvar(name)
	if name == "pitch" then
		return Polycode.Rotation_get_pitch(self.__ptr)
	elseif name == "yaw" then
		return Polycode.Rotation_get_yaw(self.__ptr)
	elseif name == "roll" then
		return Polycode.Rotation_get_roll(self.__ptr)
	end
end

function Rotation:__setvar(name,value)
	if name == "pitch" then
		Polycode.Rotation_set_pitch(self.__ptr, value)
		return true
	elseif name == "yaw" then
		Polycode.Rotation_set_yaw(self.__ptr, value)
		return true
	elseif name == "roll" then
		Polycode.Rotation_set_roll(self.__ptr, value)
		return true
	end
	return false
end
function Rotation:Rotation(...)
	local arg = {...}
	for k,v in pairs(arg) do
		if type(v) == "table" then
			if v.__ptr ~= nil then
				arg[k] = v.__ptr
			end
		end
	end
	if self.__ptr == nil and arg[1] ~= "__skip_ptr__" then
		self.__ptr = Polycode.Rotation(unpack(arg))
	end
end

function Rotation:__delete()
	if self then Polycode.delete_Rotation(self.__ptr) end
end
