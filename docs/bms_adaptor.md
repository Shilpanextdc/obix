				oBIX Adaptor to interpret BMS data files
 
Copyright (c) 2013-2014 Qingtao Cao [harry.cao@nextdc.com]    

This file contains a description of the project in the following sections:

1. Overview
2. Configuration Files
3. CSV Layer
4. Inotify Usage
5. Data Types
6. Feeder Descriptors and Contracts
7. Generic Switchboard Descriptor and Function Pointers
8. Other Pitfalls


--1-- Overview

The Building Management System (BMS) controls devices in the Main Electrical Service Network (MESN) in a data centre such as High Voltage Switch Board (HVSB), Main Switch Board (MSB), Day Tank (DT) and Bulk Tank (BT) etc. In order to comply with the NABERS requirement to record runtime meter readings and to get the PUE ratings of a data centre, the IT load and facility load need to be calculated at an interval of 5 minutes. To this end, the modbus gateway oBIX adaptors are deployed to get the IT load for each PDU to fetch the energy output readings of circuit breakers inside them, that is, the energy consumption of relevant racks, while the BMS adaptor is used to interpret the exported data of the BMS to get the overall facility load.

BTW, all the information of the Facility Load and IT load are populated onto the oBIX server as device contracts with history records saved permanently at fixed intervals, while another separate oBIX client application is needed to further fetch all needed data from the oBIX server to calculate PUE ratings.

The BMS exports the meter readings of input and output feeders on HVSBs and MSBs in comma separated version (CSV) files every 15 minutes, which are saved on one Linux based SAMBA server where the BMS adaptor is running on. Basically the BMS adaptor reads one CSV file, interprets its content, has relevant device contracts on the oBIX server updated and history records appended, then repeats until all existing CSV files are handled. Lastly the BMS adaptor waits for more CSV files generated by the BMS.


--2-- Configuration Files

The BMS adaptor uses three configuration files and can be started by the following command:

	$ cd <path-of-installation>/bin/bms_adaptor
			<path-of-installation>/etc/obix-adaptors/bms_adaptor_devices_config.xml
			<path-of-installation>/etc/obix-adaptors/bms_adaptor_config.xml
			<path-of-installation>/etc/obix-adaptors/bms_adaptor_history_template.xml

All three configuration files help extract and separate hardware connections and configurables away from the mechanism implemented by binaries, so that binaries are BMS-neutral and only these configuration files need to be tailored for different data centres without requiring to re-compile the software.

The first configuration file describes the layout of a particular MESN in a data centre, in particular, the CSV records names for relevant meter readings on different devices such as input and output feeders on a HVSB or MSB, DTs or BTs. Moreover, it also specifies the path name of the SAMBA server where BMS exports its data into and whether to rename or remove the handled CSV files.

The second configuration file captures the connection settings with the oBIX server, the client side limitations such as the maximal number of devices supported and the log facilities used.

The last configuration file provides the XML templates to assemble the History.AppendIn requests whenever history records need to be appended for relevant devices. With the help of in-memory XML DOM tree, the body of relevant HTTP requests can be generated by a simple invocation of relevant XML Parser API.


--3-- CSV Layer

The BMS adaptor manipulates another layer of wrapper APIs on top of those exported by the libcsv to organise existing CSV files and extract desirable records out of them. This extra layer is introduced in the hope to extract the high-level logic to handle CSV files from the low-level, application-specific details.

The csv_state_t is the descriptor of the CSV parser, aside from the core CSV parser structure and the buffer accommodating the content read from a CSV file, it contains a list of CSV file descriptors, a list of desirable CSV records descriptors, the inner state machine variables and an operation table pointing to application-specific functions to handle a particular type of CSV file.

The csv_file_t is the descriptor of a CSV file, depicting its file path, size and modification time. All file descriptors are organised in the strict ascending order of each file's last modification time, so that they are handled in a sequential order to ensure history records are appended successfully and relevant device contracts on the oBIX server are updated only based on the last, latest CSV file.

The csv_record_t is the descriptor of a particular desirable record in the CSV file. BMS generates more number of records than needed therefore only those needed desire to be read out. In order to ensure the CSV layer application-neutral, each record descriptor only has a void pointer and the application (e.g., the BMS adaptor) needs to point it to application-specific record descriptor (such as bms_mtr_t).

Since the BMS adaptor runs at a different pace than when BMS exports CSV files, at each round of execution (especially the first one) the adaptor's worker thread is likely to find a number of CSV files generated already in the specified folder (at different moment, see more comments below), it invokes relevant wrapper API to create descriptors for each CSV files and handle them in sequential order. Then the processed CSV files are either renamed to another directory for debug purpose or deleted permanently. All file descriptors are removed as well before the end of each round of execution to avoid potential inconsistency when CSV files are removed outside of the BMS adaptor.

The definition of CSV record descriptor varies for different applications, so does the callbacks invoked by libcsv whenever it encounters the end of each record and each field. It is the application's responsibility to provide its own specific record descriptor along with relevant callbacks to read desirable data out from one specific type of CSV file.

Last but not least, it's important to practise cautions not to copy around or touch CSV files before they are processed by the adaptor, since both cp and touch commands will update all three timestamp information in a file's inode structure, so if more than one CSV files are copied into the folder where the adaptor's worker thread is working on, they will be updated with the same last modification timestamp regardless of the fact that they were generated at different moment. Consequently, the worker thread's logic to organise and process CSV files according to their last modification timestamp will fail.


--4-- Inotify Usage

As illustrated above, BMS exports files into SAMBA server while the adaptor reads them out. What if the adaptor reads at the same time while the BMS is writing into it?

In order to cope with such race condition, the inotify object on Linux is manipulated to synchronise the adaptor's read attempt with the BMS's write operation.

At start-up an inotify object is created and loaded with a watch monitoring the folder where CSV files are generated. Once all existing CSV files are handled and relocated or deleted, the adaptor's worker thread blocks on the inotify object until it receives one of the specified events from the Linux kernel. Considering that only one CSV file is generated each time, the IN_CLOSE_WRITE event is sufficient to notify the worker thread to kick off another round of execution to proceed the newly generated file.

It's also worthwhile to mention that the worker thread needs to stop waiting for further file generation event on the reception of the IN_IGNORE event, which is sent when relevant watch and inotify objects are deleted by the main thread of the application before existing.


--5-- Data Types

Currently the BMS exports a number of different types of data in the CSV files: float, uint16_t, uint32_t and boolean. Accordingly the feeder descriptor (bms_mtr_t) manipulates a union structure as below to accommodate all data likelihood:

	typedef enum {
	    MTR_TYPE_FLOAT = 0,
    	MTR_TYPE_UINT16 = 1,
	    MTR_TYPE_UINT32 = 2,
	    MTR_TYPE_BOOL = 3,
    	MTR_TYPE_MAX = 4
	} MTR_TYPE;

	typedef struct bms_mtr {
	    /* Key or name of relevant CSV record */
    	unsigned char *key;

	    /* Value of the record */
    	union {
	        float f;
    	    uint16_t u16;
	        uint32_t u32;
    	    LVL_MTR b;
	    } value;

	    /* Type of the value read */
    	MTR_TYPE type;
	} bms_mtr_t;

Meanwhile the device configuration file depicts the layout of the whole MESN and the names and data types of desirable records of meter readings, for instance:

	<obj name="ACB">
		<kW name="Elec'MsbA'ACB'kW" type="float"/>
		<kWhR1 name="Elec'MsbA'ACB'kWhR1" type="float"/>
		<kWhR2 name="Elec'MsbA'ACB'kWhR2" type="uint16"/>
		<kWhR3 name="Elec'MsbA'ACB'kWhR3" type="uint16"/>
		<kWhR4 name="Elec'MsbA'ACB'kWhR4" type="uint16"/>
	</obj>

In above example, the input feeder (or ACB) on a MSB has 1 kW reading and 4 kWh readings. At start-up the BMS adaptor will use 5 bms_mtr_t descriptors to capture the name and data type of relevant CSV records, then when a CSV file is processed at run-time, relevant CSV records are identified properly with its value (in string format as in the CSV file) converted into the correct format


--6-- Feeder Descriptors and Contracts

In the CSV file the input and output feeders on HVSB always have 1 kW reading and 1 kWh reading, therefore they can be described by the following hvsb_fdr_t structure:

	typedef struct hvsb_fdr {
	    char *name;
    	bms_mtr_t kW;
	    bms_mtr_t kWh;
    	struct list_head list;
	} hvsb_fdr_t;

However, the number of kWh readings on the input and output feeders on MSB varies - the input feeder (or ACB, as illustrated above) always has 4 kWh readings while the output feeder has 1 ~ 2 kWh readings. Instead they are described by the following msb_fdr_t structure:

	typedef struct msb_fdr {
    	char *name;
	    bms_mtr_t kW;
    	bms_mtr_t kWh[MSB_FDR_KWH_MAX];
	    struct list_head list;
	} msb_fdr_t;

Despite the difference in the number of kWh readings, feeders XML nodes on the oBIX server are defined by one same contract:

	static const char *SB_FDR_CONTRACT =
	"<list href=\"%s\">\r\n"
	"<obj name=\"%s\" href=\"%s\" is=\"nextdc:power_meter\">\r\n"
	"<real name=\"kW\" href=\"kW\" val=\"%.1f\" writable=\"true\"/>\r\n"
	"<real name=\"kWh\" href=\"kWh\" val=\"%.1f\" writable=\"true\"/>\r\n"
	"</obj>\r\n"
	"</list>\r\n";

Obviously only one float is needed for kW and kWh readings respectively. Please refer to the "mesn.xml" file for a complete overview of all device contracts in a data centre registered and updated by the BMS adaptor.


--7-- Generic Switchboard Descriptor and Function Pointers

HVSBs and MSBs are described by the same, generic bms_sb_t structures and their difference only lie in the owner descriptors of feeders on-board as organised in the fdrs lists:

typedef struct bms_sb {
	......

    /* The list of input and output feeders */
    struct list_head fdrs[SB_FDR_LIST_MAX];

    int (*setup_fdr)(struct bms_sb *, const int, xmlNode *);
    void (*destroy_fdr)(void *);
    void (*destroy_sb)(struct bms_sb *);
    int (*for_each_fdr)(struct bms_sb *, fdr_cb_t, void *);
    int (*setup_hist)(xmlNode *, xmlNode *, xmlNode *, struct bms_sb *);
} bms_sb_t;

Function pointers are adopted in the above generic switchboard descriptor in order to abstract and separate high-level, common logic to setup, destroy, traverse and manipulate feeder descriptors on a switchboard to avoid duplication as much as possible.

At start-up the initialisation code will setup above function pointers based on the type of XML nodes of relevant switchboard in the device configuration file. This way, the high-level functions such as bms_update_sb and bms_append_history_sb are neutral to the type of a switchboard, but rely on the specific functions as pointed to by these function pointers to complete their tasks.


--8-- Other Pitfalls

Using libcsv to interpret the BMS exported data is a straightforward idea. However, cautions need to be practised to deal with the following pitfalls. Their solutions are left as a homework for readers to find in the source code ;-)

8.1 Garbage at the heading

Currently the CSV files have garbage information at the beginning such as:

	"Report Name:"  "ENERGY"
	
	"Report Status:"    "The report creation has successfully completed."
	
	
	"Name"  "Value" "Unit"  "Object Description"    "Status"    "Type"  "Parameter"
	"Chw'ChSt1'Ch01'ChkWr"  "1070.2"    "kW"    "Chiller Operating Load kWr"    "-" "Real"  "PrVal"
	"Chw'ChSt1'Ch01'HLI'kW" "66.7"  "kW"    "Chiller kW"    ""  "Real"  "PrVal"
	......

A sane CSV file should NOT contain the first 6 lines of irrelevant information.


8.2 No comma separated

Each CSV record consists of 7 fields, although they are declared to be in "CSV" files in the first place, as a matter of fact, there is no comma characters at all between fields.


8.3 Leading NULL byte

Much worse than the first two garbage, each meaningful byte in a field in current CSV files is prefixed by a leading byte of all zero as illustrated below:

	0000160: 4300 6800 7700 2700 4300 6800 5300 7400  C.h.w.'.C.h.S.t.
	0000170: 3100 2700 4300 6800 3000 3100 2700 4300  1.'.C.h.0.1.'.C.
	0000180: 6800 6b00 5700 7200 2200 0900 2200 3100  h.k.W.r."...".1.
	0000190: 3000 3700 3000 2e00 3200 2200 0900 2200  0.7.0...2."...".
	00001a0: 6b00 5700 2200 0900 2200 4300 6800 6900  k.W."...".C.h.i.
	00001b0: 6c00 6c00 6500 7200 2000 4f00 7000 6500  l.l.e.r. .O.p.e.
	00001c0: 7200 6100 7400 6900 6e00 6700 2000 4c00  r.a.t.i.n.g. .L.
	00001d0: 6f00 6100 6400 2000 6b00 5700 7200 2200  o.a.d. .k.W.r.".
	00001e0: 0900 2200 2d00 2200 0900 2200 5200 6500  ..".-."...".R.e.
	00001f0: 6100 6c00 2200 0900 2200 5000 7200 5600  a.l."...".P.r.V.
	0000200: 6100 6c00 2200 0900 0d00 0a00 2200 4300  a.l.".......".C.

They would have to be properly discarded otherwise libcsv can't parse these files at all


8.4 Mess in cases

The BMS exported CSV files have no case consistency in the naming convention of devices and meter readings, for example, "Kw", "KW" and "kW", "Crac" and "CRAC", "ACB" and "Acb" are mixed throughout each CSV file.