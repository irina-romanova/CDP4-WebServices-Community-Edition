﻿// --------------------------------------------------------------------------------------------------------------------
// <copyright file="FileBinaryService.cs" company="RHEA System S.A.">
//   Copyright (c) 2017 System RHEA System S.A.
// </copyright>
// --------------------------------------------------------------------------------------------------------------------

namespace CDP4WebServices.API.Services
{
    using System.Diagnostics;
    using System.IO;
    using System.Linq;
    using System.Security.Cryptography;
    using System.Text;

    using CDP4WebServices.API.Configuration;

    using Nancy;
    using NLog;

    /// <summary>
    /// The purpose of the <see cref="FileBinaryService"/> is to provide file functions for storage to- and retrieval from the 
    /// the file system.
    /// </summary>
    public class FileBinaryService : IFileBinaryService
    {
        /// <summary>
        /// The number of distribution levels to each stored file, alleviating the storage system from handling excessive amount of file-entries per folder.
        /// </summary>
        private const int FileStorageDistributionLevels = 6;

        /// <summary>
        /// A <see cref="NLog.Logger"/> instance
        /// </summary>
        private static readonly Logger Logger = LogManager.GetCurrentClassLogger();

        /// <summary>
        /// The root path provider.
        /// </summary>
        private readonly IRootPathProvider rootPathProvider;
        
        /// <summary>
        /// Initializes a new instance of the <see cref="FileBinaryService"/> class.
        /// </summary>
        /// <param name="rootPathProvider">
        /// The (injected) root path provider.
        /// </param>
        public FileBinaryService(IRootPathProvider rootPathProvider)
        {
            this.rootPathProvider = rootPathProvider;
        }

        /// <summary>
        /// Check whether the file is already persisted.
        /// </summary>
        /// <param name="hash">
        /// The hash of the file content.
        /// </param>
        /// <returns>
        /// True if already persisted on disk.
        /// </returns>
        public bool IsFilePersisted(string hash)
        {
            string filePath;
            return this.TryGetFileStoragePath(hash, out filePath);
        }

        /// <summary>
        /// Retrieve the binary data from disk.
        /// </summary>
        /// <param name="hash">
        /// The SHA1 hash of the the file.
        /// </param>
        /// <returns>
        /// The binary file stream handle of the file.
        /// </returns>
        /// <remarks>
        /// Binary files are stored within the system with the hash value as name
        /// </remarks>
        public Stream RetrieveBinaryData(string hash)
        {
            string filePath;

            if (!this.TryGetFileStoragePath(hash, out filePath))
            {
                throw new FileNotFoundException("The requested file does not exists");
            }

            return new FileStream(filePath, FileMode.Open);
        }

        /// <summary>
        /// Store the binary data stream on the file system.
        /// </summary>
        /// <param name="hash">
        /// The SHA1 hash of the data stream that will be stored.
        /// </param>
        /// <param name="data">
        /// The binary stream of the data that will be stored.
        /// </param>
        public void StoreBinaryData(string hash, Stream data)
        {
            var sw = new Stopwatch();
            sw.Start();
            string logMessage;

            logMessage = string.Format("Store Binary Data with hash: {0} started", hash);
            Logger.Debug(logMessage);

            string filePath;

            if (this.TryGetFileStoragePath(hash, out filePath))
            {
                logMessage = string.Format("The file already exists: {0}/{1}", filePath, hash);
                Logger.Debug(logMessage);

                // return as file already exists
                sw.Stop();
                return;
            }

            // create the path for the file
            var stroragePath = this.GetBinaryStoragePath(hash, true);
            filePath = Path.Combine(stroragePath, hash);
            
            using (var fileStream = File.Create(filePath))
            {
                data.Seek(0, SeekOrigin.Begin);
                data.CopyTo(fileStream);
            }

            logMessage = string.Format("File {0} stored in {1} [ms]", filePath, sw.ElapsedMilliseconds);
            Logger.Debug(logMessage);
        }

        /// <summary>
        /// Utility method to calculate the SHA1 hash from a stream.
        /// </summary>
        /// <param name="stream">
        /// The stream for which to calculate the hash.
        /// </param>
        /// <returns>
        /// The SHA1 hash string.
        /// </returns>
        public string CalculateHashFromStream(Stream stream)
        {
            using (var bufferedStream = new BufferedStream(stream))
            {
                using (var sha1 = new SHA1Managed())
                {
                    var hash = sha1.ComputeHash(bufferedStream);
                    var formatted = new StringBuilder(2 * hash.Length);
                    hash.ToList().ForEach(b => formatted.AppendFormat("{0:X2}", b));
                    return formatted.ToString();
                }
            }
        }

        /// <summary>
        /// The get file storage path.
        /// </summary>
        /// <param name="hash">
        /// The hash.
        /// </param>
        /// <param name="filePath">
        /// The file Path.
        /// </param>
        /// <returns>
        /// The <see cref="string"/>.
        /// </returns>
        public bool TryGetFileStoragePath(string hash, out string filePath)
        {
            var directoryPath = this.GetBinaryStoragePath(hash);
            filePath = Path.Combine(directoryPath, hash);

            return File.Exists(filePath);
        }

        /// <summary>
        /// Get the binary storage path based on the hash.
        /// </summary>
        /// <param name="hash">
        /// The binary SHA1 hash.
        /// </param>
        /// <param name="create">
        /// Flag to also create the folder structure if not present yet (for storage purposes).
        /// </param>
        /// <returns>
        /// The determined storage path from the provided hash.
        /// </returns>
        private string GetBinaryStoragePath(string hash, bool create = false)
        {
            var numberOfFileStorageDistributionLevels = FileStorageDistributionLevels;

            // using first numberOfFileStorageDistributionLevels hash characters; 
            // create a distributed folder structure numberOfFileStorageDistributionLevels levels deep in the application root of this Webserver
            var path = Path.Combine(this.rootPathProvider.GetRootPath(), AppConfig.Current.Midtier.FileStorageDirectory);
            foreach (var character in hash.ToLowerInvariant().Substring(0, numberOfFileStorageDistributionLevels).Select(x => x.ToString()))
            {
                var currentPath = Path.Combine(path, character);
                if (!Directory.Exists(currentPath) && create)
                {
                    Directory.CreateDirectory(currentPath);
                }

                path = currentPath;
            }

            return path;
        }
    }
}