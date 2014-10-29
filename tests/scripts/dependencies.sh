#!/bin/bash

##############################################################################
# Copyright (c) 2013-2014 NEXTDC LTD.
#
# This file is part of oBIX.
#
# oBIX is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# oBIX is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with oBIX.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################
 
DEPENDENCIES="lighttpd-fastcgi lighttpd libxml2 curl perl-XML-LibXML" 

for i in ${DEPENDENCIES}; do 
	if ! rpm -qi ${i} > /dev/null; then 
		echo "${i} rpm missing" 
		exit 1 
	fi 
done 

exit 0
